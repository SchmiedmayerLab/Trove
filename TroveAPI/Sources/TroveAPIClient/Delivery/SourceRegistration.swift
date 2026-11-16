//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPITypes


/// One scope-bound registration or refresh attempt. Owns no key, token, timer or retry state.
public enum SourceRegistration {
    /// Sanitized failures; response bodies and transport diagnostics are not exposed.
    public enum RegistrationError: Error, Equatable {
        case authenticationRequired
        case rejected(statusCode: Int)
        case unavailable
    }

    /// Uses the caller's existing captured-session client. Setup must already exist durably.
    /// A missing remote source is an error, never permission to register a replacement.
    public static func synchronize(
        journal: EventDeliveryJournal,
        scope: EventDeliveryJournal.Scope,
        localID: UUID,
        client: any APIProtocol,
        repositoryKind: Components.Schemas.NativeSourceRepository = .healthkit,
        validateSession: @Sendable () async throws -> Void
    ) async throws -> EventDeliveryJournal.SourceSetup {
        guard journal.scope == scope else { throw EventDeliveryJournal.JournalError.wrongScope }
        try await checkSession(validateSession)
        let setup = try await journal.sourceSetup(for: localID)
        try await checkSession(validateSession)
        // Permanent local revocation needs no remote refresh and cannot be cleared by a reply.
        if setup.binding?.isRevoked == true {
            return setup
        }
        let credential = try await journal.installationCredential(for: localID).base64EncodedString()
        let binding = try await fetch(setup, repositoryKind: repositoryKind, credential: credential, client: client)
        try await checkSession(validateSession)
        _ = try TroveDeliveryContract.source(binding, localID: localID, scope: scope)
        guard binding.source.repositoryKind == repositoryKind else { throw EventDeliveryJournal.JournalError.sourceConflict }
        let confirmed: EventDeliveryJournal.SourceSetup
        if setup.binding == nil, !binding.isRevoked {
            let recovery = try await recover(setup.registrationID, credential: credential, client: client)
            try await checkSession(validateSession)
            try TroveDeliveryContract.validateUpdate(from: binding, to: recovery.registration)
            guard let key = Data(base64Encoded: recovery.identityKeyBase64), key.count == 32,
                  key.base64EncodedString() == recovery.identityKeyBase64 else { throw RegistrationError.unavailable }
            confirmed = try await journal.confirmSource(recovery.registration, for: setup, identityKey: key)
        } else {
            confirmed = try await journal.confirmSource(binding, for: setup)
        }
        try await checkSession(validateSession)
        return confirmed
    }

    private static func checkSession(_ validate: @Sendable () async throws -> Void) async throws {
        try Task.checkCancellation()
        do {
            try await validate()
        } catch {
            try Task.checkCancellation()
            throw RegistrationError.authenticationRequired
        }
        try Task.checkCancellation()
    }

    private static func fetch(
        _ setup: EventDeliveryJournal.SourceSetup,
        repositoryKind: Components.Schemas.NativeSourceRepository,
        credential: String,
        client: any APIProtocol
    ) async throws -> Components.Schemas.ParticipantSourceRegistration {
        do {
            if setup.binding != nil {
                return try await refreshed(registrationID: setup.registrationID, client: client)
            }
            let response = try await client.postParticipantSources(
                .init(body: .json(.init(
                    registrationID: setup.registrationID.uuidString.lowercased(), repositoryKind: repositoryKind, credentialBase64: credential
                )))
            )
            switch response {
            case .ok(let value): return try value.body.json
            case .badRequest: throw RegistrationError.rejected(statusCode: 400)
            case .unauthorized: throw RegistrationError.authenticationRequired
            case .forbidden: throw RegistrationError.rejected(statusCode: 403)
            case .notFound: throw RegistrationError.rejected(statusCode: 404)
            case .conflict: throw RegistrationError.rejected(statusCode: 409)
            case .serviceUnavailable: throw RegistrationError.unavailable
            case .undocumented(let status, _): throw failure(status)
            }
        } catch {
            try Task.checkCancellation()
            throw error as? RegistrationError ?? .unavailable
        }
    }

    private static func refreshed(registrationID: UUID, client: any APIProtocol) async throws -> Components.Schemas.ParticipantSourceRegistration {
        switch try await client.getParticipantSourceInstallation(.init(path: .init(registrationId: registrationID.uuidString.lowercased()))) {
        case .ok(let value): return try value.body.json
        case .badRequest: throw RegistrationError.rejected(statusCode: 400)
        case .unauthorized: throw RegistrationError.authenticationRequired
        case .forbidden: throw RegistrationError.rejected(statusCode: 403)
        case .notFound: throw RegistrationError.rejected(statusCode: 404)
        case .undocumented(let status, _): throw failure(status)
        }
    }

    private static func recover(
        _ registrationID: UUID, credential: String, client: any APIProtocol
    ) async throws -> Components.Schemas.ParticipantSourceIdentityRecovery {
        do {
            switch try await client.recoverParticipantSourceIdentity(.init(
                path: .init(registrationId: registrationID.uuidString.lowercased()), body: .json(.init(credentialBase64: credential))
            )) {
            case .ok(let value):
                guard value.headers.cacheControl == "no-store" else { throw RegistrationError.unavailable }
                return try value.body.json
            case .badRequest: throw RegistrationError.rejected(statusCode: 400)
            case .unauthorized: throw RegistrationError.authenticationRequired
            case .forbidden: throw RegistrationError.rejected(statusCode: 403)
            case .notFound: throw RegistrationError.rejected(statusCode: 404)
            case .conflict: throw RegistrationError.rejected(statusCode: 409)
            case .serviceUnavailable: throw RegistrationError.unavailable
            case .undocumented(let status, _): throw failure(status)
            }
        } catch {
            try Task.checkCancellation()
            throw error as? RegistrationError ?? .unavailable
        }
    }

    private static func failure(_ status: Int) -> RegistrationError {
        (400...599).contains(status) ? .rejected(statusCode: status) : .unavailable
    }
}
