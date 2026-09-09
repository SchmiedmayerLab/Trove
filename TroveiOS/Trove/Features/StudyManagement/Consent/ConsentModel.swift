//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import CryptoKit
import Grove
import GroveConsent
import SwiftUI
import TroveAPIClient


@MainActor
@Observable
final class ConsentModel: Module, EnvironmentAccessible {
    enum Phase: Equatable {
        case idle, loading, reviewing, submitting, retryRequired, reviewRequired, failed, accepted
    }

    struct Transport {
        var session: @MainActor () -> KeycloakSessionSnapshot?
        var receipts: @MainActor (KeycloakSessionSnapshot, String) async throws -> [Components.Schemas.ConsentRecordResponse]
        var presentation: @MainActor (KeycloakSessionSnapshot, String, Int, String) async throws -> Components.Schemas.ConsentPresentationResponse
        var submit: @MainActor (PendingConsentCommand) async throws -> Components.Schemas.ConsentRecordResponse
        var export: @MainActor (ConsentDocument) throws -> ConsentExport = ConsentExportBridge.export
    }

    private struct Review: Equatable {
        let enrollmentID: String
        let revision: Int
        let locale: String
    }

    @ObservationIgnored @Dependency(TroveAPIModule.self) private var api
    @ObservationIgnored private let transport: Transport?
    private var owner: KeycloakSessionSnapshot?
    private var review: Review?
    private var operationID: UUID?
    private var storedPhase: Phase = .idle
    private var storedDocument: ConsentDocument?
    private var storedPresentation: Components.Schemas.ConsentPresentationResponse?
    private var storedDate: Date?
    private var storedReceipt: Components.Schemas.ConsentRecordResponse?
    private var failure: ConsentFailure?
    private var pending: PendingConsentCommand?

    var phase: Phase { isOwned ? storedPhase : .idle }
    var document: ConsentDocument? { isOwned ? storedDocument : nil }
    var presentation: Components.Schemas.ConsentPresentationResponse? { isOwned ? storedPresentation : nil }
    var reviewDate: Date? { isOwned ? storedDate : nil }
    var receipt: Components.Schemas.ConsentRecordResponse? { isOwned ? storedReceipt : nil }
    var errorMessage: LocalizedStringResource? { isOwned ? failure?.message : nil }
    var isBusy: Bool { phase == .loading || phase == .submitting }
    var pendingReview: PendingConsentReview? {
        guard isOwned, let pending, pending.session == session,
              storedPhase == .submitting || storedPhase == .retryRequired else {
            return nil
        }
        return .init(enrollmentID: pending.enrollmentID, revision: pending.reviewedRevision, locale: pending.presentation.locale)
    }

    private var session: KeycloakSessionSnapshot? {
        if let transport {
            return transport.session()
        }
        return api.sessionSnapshot
    }
    private var isOwned: Bool { owner != nil && owner == session }

    init(transport: Transport? = nil) { self.transport = transport }

    func synchronizeSession() {
        guard owner != session else {
            return
        }
        owner = session
        review = nil
        operationID = nil
        storedPhase = .idle
        storedDocument = nil
        storedPresentation = nil
        storedDate = nil
        storedReceipt = nil
        pending = nil
        failure = nil
    }

    func matches(enrollmentID: String, revision: Int, locale: String) -> Bool {
        isOwned && review == Review(enrollmentID: enrollmentID, revision: revision, locale: locale)
    }

    func open(enrollmentID: String, revision: Int, locale: String) async {
        synchronizeSession()
        guard let owner else {
            return
        }
        let requested = Review(enrollmentID: enrollmentID, revision: revision, locale: locale)
        if isBusy || storedPhase == .retryRequired {
            return
        }
        if review == requested, storedPhase == .reviewing || storedPhase == .accepted {
            return
        }
        review = requested
        let operation = UUID()
        operationID = operation
        storedPhase = .loading
        storedDocument = nil
        storedReceipt = nil
        failure = nil
        do {
            let records = try await listReceipts(owner, enrollmentID)
            guard current(owner, operation) else {
                return
            }
            if let record = records.first(where: { $0.revision == revision }) {
                try reconcile(record, requested: requested)
                operationID = nil
                return
            }
            let value = try await loadPresentation(owner, enrollmentID, revision, locale)
            guard current(owner, operation) else {
                return
            }
            try validate(value, requested: requested)
            try prepareReview(value)
            operationID = nil
        } catch {
            guard current(owner, operation) else {
                return
            }
            failure = error as? ConsentFailure ?? .unavailable
            storedPhase = .failed
            operationID = nil
        }
    }

    private func reconcile(_ record: Components.Schemas.ConsentRecordResponse, requested: Review) throws {
        // Receipt reads remain authorized after withdrawal, unlike admission of a new
        // presentation. This restores a historical acknowledgement, never active enrollment.
        guard record.enrollmentId == requested.enrollmentID, record.revision == requested.revision,
              let proof = record.presentation, proof.locale == requested.locale,
              UUID(uuidString: proof.presentationId) != nil,
              proof.digest.count == 64, proof.digest.allSatisfy({ "0123456789abcdef".contains($0) }),
              (record.acceptedEnrollmentVersion ?? 0) > 0, UUID(uuidString: record.id) != nil else {
            throw ConsentFailure.historicalReceipt
        }
        storedReceipt = record
        storedPresentation = nil
        storedDate = nil
        pending = nil
        storedPhase = .accepted
    }

    private func prepareReview(_ value: Components.Schemas.ConsentPresentationResponse) throws {
        try ConsentContentPolicy.validate(markdown: value.markdown)
        storedDocument = try ConsentDocument(markdown: value.markdown)
        storedDate = Date()
        storedPresentation = value
        pending = nil
        storedPhase = .reviewing
    }

    func submit() async {
        synchronizeSession()
        guard storedPhase == .reviewing, let owner, let review, let document = storedDocument,
              let presentation = storedPresentation else { return }
        do {
            let exported = try transport?.export(document) ?? ConsentExportBridge.export(document)
            pending = .init(
                session: owner,
                enrollmentID: review.enrollmentID,
                commandID: UUID(),
                reviewedRevision: presentation.revision,
                presentation: presentation.presentation,
                enrollmentETag: presentation.enrollmentETag,
                expectedEnrollmentVersion: presentation.enrollmentStateVersion,
                responses: exported.responses,
                pdf: exported.pdf
            )
            storedDocument = nil
            await sendPending()
        } catch {
            failure = error as? ConsentFailure ?? .preparationFailed
        }
    }

    func retry() async {
        synchronizeSession()
        guard storedPhase == .retryRequired else {
            return
        }
        await sendPending()
    }

    private func sendPending() async {
        guard let pending, pending.session == session else {
            return
        }
        let operation = UUID()
        operationID = operation
        storedPhase = .submitting
        failure = nil
        do {
            let record = try await send(pending)
            guard current(pending.session, operation) else {
                return
            }
            guard pending.validates(record) else { throw ConsentFailure.outcomeUnknown }
            storedReceipt = record
            self.pending = nil
            storedPhase = .accepted
        } catch {
            guard current(pending.session, operation) else {
                return
            }
            failure = error as? ConsentFailure ?? .outcomeUnknown
            switch failure {
            case .reviewRequired, .accessDenied, .signInRequired, .pdfTooLarge, .invalidPresentation:
                storedPhase = .reviewRequired
            default: storedPhase = .retryRequired
            }
        }
        operationID = nil
    }

    private func current(_ owner: KeycloakSessionSnapshot, _ operation: UUID) -> Bool {
        self.owner == owner && session == owner && operationID == operation
    }

    private func validate(_ value: Components.Schemas.ConsentPresentationResponse, requested: Review) throws {
        let digest = SHA256.hash(data: Data(value.markdown.utf8)).map { String(format: "%02x", $0) }.joined()
        guard value.revision == requested.revision, value.revision > 0,
              value.presentation.locale == requested.locale, !requested.locale.isEmpty,
              UUID(uuidString: value.presentation.presentationId) != nil, value.presentation.digest == digest,
              value.enrollmentStateVersion > 0, value.enrollmentStateVersion < Int64.max,
              !value.enrollmentETag.isEmpty else {
            throw ConsentFailure.invalidPresentation
        }
    }

    private func listReceipts(_ session: KeycloakSessionSnapshot, _ enrollment: String) async throws -> [Components.Schemas.ConsentRecordResponse] {
        if let transport {
            return try await transport.receipts(session, enrollment)
        }
        return try await api.requireClient(for: session).getParticipantEnrollmentsEnrollmentIdConsents(
            .init(path: .init(enrollmentId: enrollment))
        ).ok.body.json
    }

    private func loadPresentation(
        _ session: KeycloakSessionSnapshot, _ enrollment: String, _ revision: Int, _ locale: String
    ) async throws -> Components.Schemas.ConsentPresentationResponse {
        if let transport {
            return try await transport.presentation(session, enrollment, revision, locale)
        }
        return try await api.requireClient(for: session).getParticipantEnrollmentsEnrollmentIdConsentPresentation(
            .init(path: .init(enrollmentId: enrollment), query: .init(locale: locale, revision: revision))
        ).ok.body.json
    }

    private func send(_ command: PendingConsentCommand) async throws -> Components.Schemas.ConsentRecordResponse {
        if let transport {
            return try await transport.submit(command)
        }
        switch try await api.requireClient(for: command.session).postParticipantEnrollmentsEnrollmentIdConsents(command.input()) {
        case .created(let response): return try response.body.json
        case .conflict, .preconditionFailed: throw ConsentFailure.reviewRequired
        case .unauthorized: throw ConsentFailure.signInRequired
        case .forbidden, .notFound: throw ConsentFailure.accessDenied
        case .badRequest: throw ConsentFailure.invalidPresentation
        case .undocumented(let status, _):
            throw status == 413 ? ConsentFailure.pdfTooLarge : ConsentFailure.outcomeUnknown
        }
    }
}
