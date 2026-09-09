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
        validateSession: @Sendable () async throws -> Void
    ) async throws -> EventDeliveryJournal.SourceSetup {
        guard journal.scope == scope else { throw EventDeliveryJournal.JournalError.wrongScope }
        try await checkSession(validateSession)
        let setup = try await journal.sourceSetup(for: localID)
        try await checkSession(validateSession)
        // Permanent local revocation needs no remote refresh and cannot be cleared by a reply.
        if setup.binding?.revokedAt != nil {
            return setup
        }
        let binding = try await fetch(setup, client: client)
        try await checkSession(validateSession)
        let confirmed = try await journal.confirmSource(binding, for: setup)
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
        _ setup: EventDeliveryJournal.SourceSetup, client: any APIProtocol
    ) async throws -> Components.Schemas.ParticipantSource {
        do {
            if let binding = setup.binding {
                return try await refreshed(sourceID: binding.id, client: client)
            }
            let response = try await client.postParticipantSources(
                .init(body: .json(.init(registrationID: setup.registrationID.uuidString.lowercased())))
            )
            switch response {
            case .ok(let value): return try value.body.json
            case .badRequest: throw RegistrationError.rejected(statusCode: 400)
            case .unauthorized: throw RegistrationError.authenticationRequired
            case .forbidden: throw RegistrationError.rejected(statusCode: 403)
            case .notFound: throw RegistrationError.rejected(statusCode: 404)
            case .undocumented(let status, _): throw failure(status)
            }
        } catch let error as RegistrationError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw RegistrationError.unavailable
        }
    }

    private static func refreshed(sourceID: String, client: any APIProtocol) async throws -> Components.Schemas.ParticipantSource {
        switch try await client.getParticipantSourcesSourceId(.init(path: .init(sourceId: sourceID))) {
        case .ok(let value): return try value.body.json
        case .badRequest: throw RegistrationError.rejected(statusCode: 400)
        case .unauthorized: throw RegistrationError.authenticationRequired
        case .forbidden: throw RegistrationError.rejected(statusCode: 403)
        case .notFound: throw RegistrationError.rejected(statusCode: 404)
        case .undocumented(let status, _): throw failure(status)
        }
    }

    private static func failure(_ status: Int) -> RegistrationError {
        (400...599).contains(status) ? .rejected(statusCode: status) : .unavailable
    }
}
