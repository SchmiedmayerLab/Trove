//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if canImport(HealthKit)

import Foundation
import GroveFHIRContract
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
import TroveAPIClient


/// One bounded acquisition pass. The caller owns scheduling, permissions and the captured session;
/// the journal owns the only durable key, anchor and delivery queue.
public struct HeartRateAcquisition: Sendable {
    /// Progress of one atomic query page, before consent filtering removes individual samples.
    public struct Page: Sendable {
        public let eventIDs: [UUID]
        public let changeCount: Int

        /// Only an empty HealthKit delta establishes that this query reached its current end.
        public var isCaughtUp: Bool { changeCount == 0 }
    }

    public enum Progress: Sendable, Equatable { case caughtUp, needsAnotherPass }

    public enum AcquisitionError: Error, Equatable {
        case authenticationRequired
        case authorityChanged
        case invalidQueryDefinition
        case unavailable
        case unsupportedDelta
    }

    struct Delta: Sendable {
        let added: [HKQuantitySample]
        let deletedIDs: [UUID]
        let nextAnchor: QueryAnchor
    }

    struct Definition: Codable {
        let adapter: String
        let version: Int
        let start: Date
    }

    let journal: EventDeliveryJournal
    let scope: EventDeliveryJournal.Scope
    let client: any APIProtocol
    let validateSession: @Sendable () async throws -> Void

    public init(
        journal: EventDeliveryJournal,
        scope: EventDeliveryJournal.Scope,
        client: any APIProtocol,
        validateSession: @escaping @Sendable () async throws -> Void
    ) throws {
        guard journal.scope == scope else { throw EventDeliveryJournal.JournalError.wrongScope }
        self.journal = journal
        self.scope = scope
        self.client = client
        self.validateSession = validateSession
    }

    /// Persist once through explicit `journal.createSource`; never replace a definition when restoring.
    public static func queryDefinition(start: Date) throws -> Data {
        guard (0...253_402_300_799).contains(start.timeIntervalSince1970) else { throw AcquisitionError.invalidQueryDefinition }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Version 2 derives complete identity namespaces instead of appending paths to URNs.
        return try encoder.encode(Definition(adapter: "healthkit-heart-rate", version: 2, start: start))
    }

    static func catchUp(nextPage: @Sendable () async throws -> Page) async throws -> Progress {
        for _ in 0..<8 {
            try Task.checkCancellation()
            let page = try await nextPage()
            try Task.checkCancellation()
            if page.isCaughtUp {
                return .caughtUp
            }
        }
        return .needsAnotherPass
    }

    /// Checks current authority before explicit stream creation or a permission request.
    /// This never reads HealthKit, creates a source, or changes an established query.
    public func prepareQueryDefinition(enrollmentIDs: [UUID]) async throws -> Data {
        let snapshot = try await collectionSnapshot(enrollmentIDs)
        try await checkSession()
        guard let start = snapshot.heartRateQueryStart else { throw ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized }
        return try Self.queryDefinition(start: start)
    }

    /// Uses Grove's caller-owned anchored query. It neither prompts for permission nor enables background collection.
    /// Returned IDs refer to durable events ready for the existing session-bound delivery drainer.
    public func collect(localID: UUID, enrollmentIDs: [UUID], healthKit: GroveHealthKit.HealthKit) async throws -> Page {
        try await collect(localID: localID, enrollmentIDs: enrollmentIDs, application: .main, host: .current) { start, previous in
            var anchor = previous
            let changes = try await healthKit.query(.heartRate, timeRange: .startingAt(start), anchor: &anchor, limit: 64)
            return Delta(added: changes.added, deletedIDs: changes.deleted.map(\.uuid), nextAnchor: anchor)
        }
    }

    /// Advances at most eight pages, rechecking source/session/consent authority for every page.
    /// Cancellation or failure preserves completed pages; a later pass resumes their durable anchor.
    public func catchUp(localID: UUID, enrollmentIDs: [UUID], healthKit: GroveHealthKit.HealthKit) async throws -> Progress {
        try await Self.catchUp {
            try await collect(localID: localID, enrollmentIDs: enrollmentIDs, healthKit: healthKit)
        }
    }

    func collect(
        localID: UUID,
        enrollmentIDs: [UUID],
        application: HealthKitApplication,
        host: HealthKitHostDevice,
        query: @Sendable (Date, QueryAnchor) async throws -> Delta
    ) async throws -> Page {
        let source = try await synchronize(localID)
        guard let binding = source.binding, binding.revokedAt == nil, let sourceID = UUID(uuidString: binding.id) else {
            throw EventDeliveryJournal.JournalError.sourceRevoked
        }
        let checkpoint = try await journal.checkpoint(for: sourceID)
        let definition = try JSONDecoder().decode(Definition.self, from: checkpoint.queryDefinition)
        guard definition.adapter == "healthkit-heart-rate", definition.version == 2,
              try Self.queryDefinition(start: definition.start) == checkpoint.queryDefinition else {
            throw AcquisitionError.invalidQueryDefinition
        }
        let anchor = try checkpoint.cursor.map { try JSONDecoder().decode(QueryAnchor.self, from: $0) } ?? QueryAnchor()
        let privacy = try await journal.identityScope(for: sourceID)
        let before = try await collectionSnapshot(enrollmentIDs)
        guard before.permitsHeartRateAcquisition else { throw ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized }
        try await checkSession()
        let delta = try await query(definition.start, anchor)
        try await checkSession()
        let changeCount = delta.added.count + delta.deletedIDs.count
        guard changeCount <= 128, delta.nextAnchor != QueryAnchor(),
              changeCount == 0 || delta.nextAnchor != anchor else {
            throw AcquisitionError.unsupportedDelta
        }
        let refreshed = try await synchronize(localID)
        let after = try await collectionSnapshot(enrollmentIDs)
        guard refreshed == source, before.hasSameAuthority(as: after) else { throw AcquisitionError.authorityChanged }
        let context = ConversionInputs(source: binding, privacy: privacy, application: application, host: host, instant: Date())
        let cursor = try JSONEncoder().encode(delta.nextAnchor)
        try await checkSession()
        let ids = try await journal.stage(from: checkpoint, nextCursor: cursor, changeCount: changeCount) { index, sequence in
            if index < delta.added.count {
                return try Self.payload(delta.added[index], sequence: sequence, snapshot: after, context: context)
            }
            return try Self.retraction(delta.deletedIDs[index - delta.added.count], sequence: sequence, context: context)
        }
        try await checkSession()
        return Page(eventIDs: ids, changeCount: changeCount)
    }
}


extension HeartRateAcquisition {
    private func synchronize(_ localID: UUID) async throws -> EventDeliveryJournal.SourceSetup {
        try await SourceRegistration.synchronize(journal: journal, scope: scope, localID: localID, client: client, validateSession: validateSession)
    }

    private func collectionSnapshot(_ ids: [UUID]) async throws -> ParticipantCollectionSnapshot {
        guard ids.count <= 128, Set(ids).count == ids.count else { throw ParticipantCollectionSnapshot.CollectionError.invalidPlan }
        var plans: [Components.Schemas.ParticipantCollectionPlan] = []
        for id in ids {
            try await checkSession()
            do {
                let response = try await client.getParticipantCollectionPlan(.init(path: .init(enrollmentId: id.uuidString.lowercased())))
                plans.append(try response.ok.body.json)
            } catch {
                try Task.checkCancellation()
                throw AcquisitionError.unavailable
            }
            try await checkSession()
        }
        return try ParticipantCollectionSnapshot(plans: plans, enrollmentIDs: ids)
    }

    private func checkSession() async throws {
        try Task.checkCancellation()
        do {
            try await validateSession()
        } catch {
            try Task.checkCancellation()
            throw AcquisitionError.authenticationRequired
        }
        try Task.checkCancellation()
    }
}

#endif
