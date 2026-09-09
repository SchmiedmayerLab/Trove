//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import TroveAPITypes


/// Performs bounded delivery passes with a captured-session client. Owns no token, timer or source checkpoint.
public actor EventDeliveryDrainer {
    public struct Outcome: Sendable, Equatable {
        public let deliveryID: UUID
        public let status: EventDeliveryJournal.DeliveryStatus
    }

    public enum DeliveryError: Error, Equatable {
        case drainInProgress
        case authenticationRequired
    }

    private enum Response {
        case receipt(Components.Schemas.EventReceipt)
        case status(Int, retryAfter: Date? = nil)
    }

    private enum BatchError: Error { case invalidResponse }

    private let journal: EventDeliveryJournal
    private let client: any APIProtocol
    private let validateSession: @Sendable () async throws -> Void
    private let now: @Sendable () -> Date
    private var isDraining = false
    private var authenticationFailed = false

    /// The caller supplies the existing authenticated client for exactly this scope and session generation.
    public init(
        journal: EventDeliveryJournal,
        scope: EventDeliveryJournal.Scope,
        client: any APIProtocol,
        validateSession: @escaping @Sendable () async throws -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard journal.scope == scope else { throw EventDeliveryJournal.JournalError.wrongScope }
        self.journal = journal
        self.client = client
        self.validateSession = validateSession
        self.now = now
    }

    /// A failed session stops this instance until a new captured-session drainer is constructed.
    /// Completed members remain committed when a later member fails or the task is cancelled.
    public func drain(limit: Int = 16) async throws -> [Outcome] {
        guard !isDraining else { throw DeliveryError.drainInProgress }
        isDraining = true
        defer { isDraining = false }
        try await checkSession()
        let ids = try await journal.readyDeliveryIDs(at: now(), limit: limit)
        var processed: [UUID] = []
        var batch = EventDeliveryBatch()
        for id in ids {
            try await checkSession()
            guard let attempt = try await journal.prepareAttempt(id, at: now()) else { continue }
            processed.append(id)
            guard try await requiresSubmission(attempt) else { continue }
            let member = try EventDeliveryBatch.Member(attempt)
            if !batch.append(member) {
                try await deliver(batch)
                batch = EventDeliveryBatch()
                guard batch.append(member) else {
                    try await apply(.status(413), to: attempt)
                    continue
                }
            }
            if batch.members.count == EventSubmissionLimits.maximumBatchEvents {
                try await deliver(batch)
                batch = EventDeliveryBatch()
            }
        }
        try await deliver(batch)
        var outcomes: [Outcome] = []
        for id in processed {
            try await checkSession()
            outcomes.append(Outcome(deliveryID: id, status: try await journal.status(for: id)))
        }
        try await checkSession()
        return outcomes
    }

    private func checkSession() async throws {
        try Task.checkCancellation()
        guard !authenticationFailed else { throw DeliveryError.authenticationRequired }
        do {
            try await validateSession()
        } catch {
            try Task.checkCancellation()
            authenticationFailed = true
            throw DeliveryError.authenticationRequired
        }
        try Task.checkCancellation()
    }
}


extension EventDeliveryDrainer {
    private func requiresSubmission(_ attempt: EventDeliveryJournal.Attempt) async throws -> Bool {
        guard attempt.custodyWasUncertain else {
            return true
        }
        let response: Response
        do {
            try await checkSession()
            response = try await lookup(attempt)
            try await checkSession()
        } catch {
            try await checkSession()
            try await retry(attempt, notBefore: nil)
            return false
        }
        if case .status(404, _) = response {
            return true
        }
        try await apply(response, to: attempt)
        return false
    }

    private func deliver(_ batch: EventDeliveryBatch) async throws {
        guard !batch.members.isEmpty else {
            return
        }
        let responses: [Response]
        do {
            try await checkSession()
            responses = try await submit(batch)
            try await checkSession()
        } catch {
            // An unparseable or lost response leaves every submitted member uncertain.
            try await checkSession()
            for member in batch.members { try await retry(member.attempt, notBefore: nil) }
            return
        }
        if responses.contains(where: { if case .status(401, _) = $0 { true } else { false } }) {
            authenticationFailed = true
            throw DeliveryError.authenticationRequired
        }
        for (member, response) in zip(batch.members, responses) {
            try await apply(response, to: member.attempt)
        }
    }

    private func apply(_ response: Response, to attempt: EventDeliveryJournal.Attempt) async throws {
        try await checkSession()
        switch response {
        case .receipt(let receipt):
            do {
                try attempt.commitment.verify(receipt)
            } catch {
                try await journal.block(attempt.deliveryID, reason: .invalidReceipt)
                return
            }
            try await journal.recordReceipt(receipt, for: attempt.deliveryID)
        case .status(401, _):
            authenticationFailed = true
            throw DeliveryError.authenticationRequired
        case let .status(code, deadline) where code == 408 || code == 429 || (500...599).contains(code):
            try await retry(attempt, notBefore: deadline)
        case .status(let code, _):
            try await journal.block(attempt.deliveryID, reason: .rejected(statusCode: code))
        }
    }

    private func retry(_ attempt: EventDeliveryJournal.Attempt, notBefore serverDeadline: Date?) async throws {
        let ceiling = min(300, 5 * pow(2, Double(min(attempt.attemptCount - 1, 6))))
        let delay = Double.random(in: ceiling * 0.8...ceiling)
        let deadline = max(now().addingTimeInterval(delay), serverDeadline ?? .distantPast)
        try await journal.deferRetry(attempt.deliveryID, until: deadline)
    }
}


extension EventDeliveryDrainer {
    private func lookup(_ attempt: EventDeliveryJournal.Attempt) async throws -> Response {
        let response = try await client.lookupParticipantEventReceipt(.init(
            path: .init(sourceId: attempt.commitment.sourceID.uuidString.lowercased()), body: .json(attempt.commitment.receiptLookup)
        ))
        switch response {
        case .ok(let value): return .receipt(try value.body.json)
        case .badRequest: return .status(400)
        case .unauthorized: return .status(401)
        case .forbidden: return .status(403)
        case .notFound: return .status(404)
        case .conflict: return .status(409)
        case .contentTooLarge: return .status(413)
        case .internalServerError: return .status(500)
        case let .undocumented(code, payload): return .status(code, retryAfter: retryAfter(payload.headerFields[.retryAfter]))
        }
    }

    private func submit(_ batch: EventDeliveryBatch) async throws -> [Response] {
        guard let first = batch.members.first else { throw BatchError.invalidResponse }
        let response = try await client.submitParticipantEventBatch(.init(
            path: .init(sourceId: first.attempt.commitment.sourceID.uuidString.lowercased()),
            body: .json(.init(events: batch.members.map(\.submission)))
        ))
        let failure: Response
        switch response {
        case .ok(let value):
            return try batchResponses(value.body.json, expectedCount: batch.members.count)
        case .badRequest: failure = .status(400)
        case .unauthorized: failure = .status(401)
        case .forbidden: failure = .status(403)
        case .notFound: failure = .status(404)
        case .conflict: failure = .status(409)
        case .contentTooLarge: failure = .status(413)
        case .internalServerError: failure = .status(500)
        case let .undocumented(code, payload): failure = .status(code, retryAfter: retryAfter(payload.headerFields[.retryAfter]))
        }
        return Array(repeating: failure, count: batch.members.count)
    }

    private func batchResponses(_ results: [Components.Schemas.EventBatchResult], expectedCount: Int) throws -> [Response] {
        guard results.count == expectedCount else { throw BatchError.invalidResponse }
        return try results.map { result in
            switch result {
            case .EventReceipt(let receipt): return .receipt(receipt)
            case .ProblemDetails(let problem):
                guard (400...599).contains(problem.status) else { throw BatchError.invalidResponse }
                return .status(problem.status)
            }
        }
    }

    private func retryAfter(_ value: String?) -> Date? {
        guard let value, (1...128).contains(value.utf8.count) else {
            return nil
        }
        if value.utf8.allSatisfy({ (48...57).contains($0) }), let seconds = Double(value), seconds.isFinite {
            let deadline = now().addingTimeInterval(seconds)
            return deadline.timeIntervalSince1970 <= 253_402_300_799 ? deadline : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        formatter.isLenient = false
        guard let deadline = formatter.date(from: value),
              deadline.timeIntervalSince1970.isFinite, deadline.timeIntervalSince1970 <= 253_402_300_799 else {
            return nil
        }
        return deadline
    }
}
