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
import HealthKit
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import TroveAPIClient
@testable import TroveHealthKit


struct HeartRateAcquisitionTests {
    private enum Interruption: CaseIterable { case queryFailure, cancellation }
    private enum QueryFailure: Error { case unavailable }

    @Test(arguments: ["https://trove.test/events", "urn:uuid:19e5294b-859b-4670-8c58-9f34f5417cd1"])
    func groveConversionStagesOneEventForTwoStudiesAndRestoresExactBytes(identifierRoot: String) async throws {
        try await Self.withFixture(identifierRoot: identifierRoot) { fixture, url in
            let ids = try await fixture.collect { _, anchor in
                #expect(anchor == QueryAnchor())
                return Self.delta([Self.sample()])
            }
            #expect(ids.count == 1)
            let id = try #require(ids.first)
            let attempt = try #require(try await fixture.journal.prepareAttempt(id))
            #expect(attempt.commitment.targetIntent.targets.count == 2)
            let targets = attempt.commitment.targetIntent.targets
            #expect(targets[0].outputFullURLs == targets[1].outputFullURLs)
            let object = try #require(JSONSerialization.jsonObject(with: attempt.bytes) as? [String: Any])
            let entries = try #require(object["entry"] as? [[String: Any]])
            let observations = entries.compactMap { $0["resource"] as? [String: Any] }.filter { $0["resourceType"] as? String == "Observation" }
            #expect(observations.count == 1)
            let checkpoint = try await fixture.journal.checkpoint(for: fixture.sourceID)
            #expect(try checkpoint.cursor.map { try JSONDecoder().decode(QueryAnchor.self, from: $0) } == Self.nextAnchor)
            await fixture.journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            do {
                #expect(try await reopened.checkpoint(for: fixture.sourceID) == checkpoint)
                let restored = try #require(try await reopened.prepareAttempt(id))
                #expect(restored.bytes == attempt.bytes)
                #expect(restored.commitment.payloadSHA256 == attempt.commitment.payloadSHA256)
                #expect(restored.commitment.targetIntent.serialized == attempt.commitment.targetIntent.serialized)
            } catch {
                await reopened.close()
                throw error
            }
            await reopened.close()
        }
    }

    @Test
    func withdrawalDuringQueryRollsBackThenNextPassUsesOnlyRemainingStudy() async throws {
        try await Self.withFixture { fixture, _ in
            let before = try await fixture.journal.checkpoint(for: fixture.sourceID)
            await #expect(throws: HeartRateAcquisition.AcquisitionError.authorityChanged) {
                try await fixture.collect { _, _ in
                    await fixture.transport.withdrawFirstStudy()
                    return Self.delta([Self.sample()])
                }
            }
            #expect(try await fixture.journal.checkpoint(for: fixture.sourceID) == before)
            #expect(try await fixture.journal.pendingDeliveryIDs().isEmpty)
            let ids = try await fixture.collect { _, _ in Self.delta([Self.sample()]) }
            let id = try #require(ids.first)
            let attempt = try #require(try await fixture.journal.prepareAttempt(id))
            #expect(attempt.commitment.targetIntent.targets.count == 1)
        }
    }

    @Test
    func sessionLossDuringQueryCannotStageIntoAnotherAccount() async throws {
        try await Self.withFixture { fixture, _ in
            let before = try await fixture.journal.checkpoint(for: fixture.sourceID)
            await #expect(throws: HeartRateAcquisition.AcquisitionError.authenticationRequired) {
                try await fixture.collect { _, _ in
                    await fixture.session.invalidate()
                    return Self.delta([Self.sample()])
                }
            }
            #expect(try await fixture.journal.checkpoint(for: fixture.sourceID) == before)
            #expect(try await fixture.journal.pendingDeliveryIDs().isEmpty)
        }
    }

    @Test(arguments: ["oversized-mixed", "unsupported-sample", "missing-anchor", "oversized"])
    func unsupportedChangesNeverCommitAValidPrefixOrAdvanceTheAnchor(failure: String) async throws {
        try await Self.withFixture { fixture, _ in
            let before = try await fixture.journal.checkpoint(for: fixture.sourceID)
            await #expect(throws: HeartRateAcquisition.AcquisitionError.unsupportedDelta) {
                try await fixture.collect { _, _ in
                    switch failure {
                    case "oversized-mixed":
                        return .init(added: [Self.sample()], deletedIDs: Array(repeating: UUID(), count: 128), nextAnchor: Self.nextAnchor)
                    case "unsupported-sample": return Self.delta([Self.sample(), Self.sample(type: .stepCount)])
                    case "missing-anchor": return .init(added: [Self.sample()], deletedIDs: [], nextAnchor: QueryAnchor())
                    default: return Self.delta(Array(repeating: Self.sample(), count: 129))
                    }
                }
            }
            #expect(try await fixture.journal.checkpoint(for: fixture.sourceID) == before)
            #expect(try await fixture.journal.pendingDeliveryIDs().isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func roundingCannotCrossAnExactConsentBoundary(roundsUp: Bool) async throws {
        try await Self.withFixture { fixture, _ in
            let boundary = Self.start.addingTimeInterval(roundsUp ? 0.0006 : 0.0004)
            await fixture.transport.setConsentStart(boundary)
            let instant = Self.start.addingTimeInterval(roundsUp ? 0.00055 : 0.00045)
            let ids = try await fixture.collect { _, _ in Self.delta([Self.sample(at: instant)]) }
            #expect(ids.isEmpty)
            #expect(try await fixture.journal.checkpoint(for: fixture.sourceID).cursor != nil)
            #expect(try await fixture.journal.pendingDeliveryIDs().isEmpty)
        }
    }

    @Test
    func malformedAnchorNeverRestartsHistoryFromAnEmptyAnchor() async throws {
        try await Self.withFixture { fixture, url in
            let connection = try DeliverySQLite(url: url)
            try connection.execute("UPDATE source_state SET cursor = x'00' WHERE source_id = ?", [.text(fixture.sourceID.uuidString.lowercased())])
            connection.close()
            await #expect(throws: DecodingError.self) {
                try await fixture.collect { _, _ in
                    Issue.record("A damaged anchor must not reach HealthKit")
                    return Self.delta([])
                }
            }
            #expect(try await fixture.journal.checkpoint(for: fixture.sourceID).cursor == Data([0]))
        }
    }

    @Test
    func emptyResultCanAdvanceTheAnchorWithoutCreatingAnEvent() async throws {
        try await Self.withFixture { fixture, _ in
            let page = try await fixture.collectPage { _, _ in Self.delta([]) }
            #expect(page.eventIDs.isEmpty && page.changeCount == 0 && page.isCaughtUp)
            #expect(try await fixture.journal.checkpoint(for: fixture.sourceID).cursor != nil)
        }
    }

    @Test
    func excludedSamplesAdvanceTheCursorButDoNotEndCatchUp() async throws {
        try await Self.withFixture { fixture, _ in
            let page = try await fixture.collectPage { _, _ in Self.delta([Self.sample(at: Self.start.addingTimeInterval(-1))]) }
            #expect(page.eventIDs.isEmpty && page.changeCount == 1 && !page.isCaughtUp)
            #expect(try await fixture.journal.checkpoint(for: fixture.sourceID).cursor != nil)
            #expect(try await fixture.journal.pendingDeliveryIDs().isEmpty)
        }
    }

    @Test(arguments: Interruption.allCases)
    private func interruptedCatchUpResumesFromTheLastDurablePageAfterReopening(interruption: Interruption) async throws {
        try await Self.withFixture { fixture, url in
            let secondAnchor = QueryAnchor(HKQueryAnchor(fromValue: 2))
            await fixture.interruptCatchUp(interruption)
            let checkpoint = try await fixture.journal.checkpoint(for: fixture.sourceID)
            #expect(try checkpoint.cursor.map { try JSONDecoder().decode(QueryAnchor.self, from: $0) } == Self.nextAnchor)
            let firstIDs = try await fixture.journal.pendingDeliveryIDs()
            #expect(firstIDs.count == 1)
            let firstID = try #require(firstIDs.first)
            let original = try #require(try await fixture.journal.prepareAttempt(firstID))
            await fixture.journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            do {
                #expect(try await reopened.checkpoint(for: fixture.sourceID) == checkpoint)
                let restored = try fixture.using(reopened)
                let progress = try await HeartRateAcquisition.catchUp {
                    try await restored.collectPage { _, anchor in
                        if anchor == Self.nextAnchor {
                            return .init(added: [Self.sample()], deletedIDs: [], nextAnchor: secondAnchor)
                        }
                        #expect(anchor == secondAnchor)
                        return .init(added: [], deletedIDs: [], nextAnchor: secondAnchor)
                    }
                }
                #expect(progress == .caughtUp)
                let ids = try await reopened.pendingDeliveryIDs()
                #expect(ids.count == 2 && ids.contains(firstID))
                let retained = try #require(try await reopened.prepareAttempt(firstID))
                #expect(retained.bytes == original.bytes && retained.commitment.sourceID == original.commitment.sourceID)
                #expect(retained.commitment.targetIntent.serialized == original.commitment.targetIntent.serialized)
            } catch {
                await reopened.close()
                throw error
            }
            await reopened.close()
        }
    }

    @Test
    func mixedDeltaRetractsTheExactGroveOutputWithoutCopyingSamplesOrConsentTargets() async throws {
        try await Self.withFixture { fixture, _ in
            let sample = Self.sample()
            let ids = try await fixture.collect { _, _ in
                .init(added: [Self.sample(at: Self.start.addingTimeInterval(-1)), sample], deletedIDs: [sample.uuid], nextAnchor: Self.nextAnchor)
            }
            #expect(ids.count == 2)
            let firstID = try #require(ids.first), lastID = try #require(ids.last)
            let addition = try #require(try await fixture.journal.prepareAttempt(firstID))
            let deletion = try #require(try await fixture.journal.prepareAttempt(lastID))
            let active = try ExchangeGraph(validating: addition.bytes, kind: .active)
            let retracted = try ExchangeGraph(validating: deletion.bytes, kind: .retraction)
            #expect(active.eventIdentifier.sequence.rawValue == "1")
            #expect(retracted.eventIdentifier.sequence.rawValue == "2")
            #expect(deletion.commitment.targetIntent.targets.isEmpty)
            #expect(retracted.bundle.entry?.count == 1)
            let observation = try #require(active.bundle.entry?.compactMap { entry in
                if case .observation(let value)? = entry.resource {
                    return value
                }
                return nil
            }.first)
            guard case .provenance(let provenance)? = retracted.bundle.entry?.first?.resource else {
                Issue.record("Retraction must contain only Provenance")
                return
            }
            let identities = try (observation.identifier ?? []).map(RoledIdentifier.init)
            #expect(try provenance.target.map { try RoledIdentifier(#require($0.identifier)) } == identities.filter { $0.role == .sourceOutput })
            let source = try #require(provenance.entity?.first?.what.identifier)
            #expect(try RoledIdentifier(source) == identities.first { $0.role == .sourceRecord })
            guard case .period(let occurred)? = provenance.occurred else {
                Issue.record("Unknown deletion time must not become a fabricated exact timestamp")
                return
            }
            #expect(occurred.start == nil && occurred.end?.value != nil)
            #expect(!String(decoding: deletion.bytes, as: UTF8.self).lowercased().contains(sample.uuid.uuidString.lowercased()))
        }
    }

    @Test
    func aDeletionDoesNotRequireAnAvailableOriginalSample() async throws {
        try await Self.withFixture { fixture, _ in
            let ids = try await fixture.collect { _, _ in
                .init(added: [], deletedIDs: [UUID()], nextAnchor: Self.nextAnchor)
            }
            let id = try #require(ids.first)
            let attempt = try #require(try await fixture.journal.prepareAttempt(id))
            #expect(attempt.commitment.targetIntent.targets.isEmpty)
            #expect(try ExchangeGraph(validating: attempt.bytes, kind: .retraction).bundle.entry?.count == 1)
        }
    }
}


extension HeartRateAcquisitionTests {
    @Test
    func exportBeforeFailedStagingRestoresExactActiveAndRetractionBytes() async throws {
        try await Self.withFixture { fixture, url in
            let sample = Self.sample()
            let delta = HeartRateAcquisition.Delta(added: [sample], deletedIDs: [sample.uuid], nextAnchor: Self.nextAnchor)
            let checkpoint = try await fixture.journal.checkpoint(for: fixture.sourceID)
            let original = try await Self.uncommittedPayloads(delta, fixture: fixture, journal: fixture.journal)
            #expect(original.count == 2)
            await #expect(throws: EventDeliveryJournal.JournalError.invalidConfiguration) {
                try await fixture.journal.stage(from: checkpoint, nextCursor: Data(), payloads: original)
            }
            #expect(try await fixture.journal.checkpoint(for: fixture.sourceID) == checkpoint)
            #expect(try await fixture.journal.pendingDeliveryIDs().isEmpty)
            await fixture.journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            do {
                let retry = try await Self.uncommittedPayloads(delta, fixture: fixture, journal: reopened)
                #expect(retry.map(\.bytes) == original.map(\.bytes))
                #expect(retry.map(\.targets) == original.map(\.targets))
                let ids = try await reopened.stage(
                    from: checkpoint, nextCursor: Data([1]), payloads: retry, observedDeletions: delta.deletedIDs
                )
                #expect(ids.count == 2)
            } catch {
                await reopened.close()
                throw error
            }
            await reopened.close()
        }
    }
}


extension HeartRateAcquisitionTests {
    private static func uncommittedPayloads(
        _ delta: HeartRateAcquisition.Delta, fixture: Fixture, journal: EventDeliveryJournal
    ) async throws -> [EventDeliveryJournal.Payload] {
        let snapshot = try await ParticipantCollectionSnapshot(plans: fixture.transport.plans, enrollmentIDs: fixture.enrollmentIDs)
        let checkpoint = try await journal.checkpoint(for: fixture.sourceID)
        let detections = try await journal.deletionDetections(for: delta.deletedIDs, from: checkpoint, at: Date())
        let exporter = try await HeartRateAcquisition.exporter(
            source: fixture.transport.binding,
            privacy: journal.identityScope(for: fixture.sourceID),
            application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
            host: .init(operatingSystemVersion: "26.0"),
            storage: journal.producerStorage(from: checkpoint)
        )
        // Dropping the unreleased receipts models interruption before the cursor commit.
        return try await HeartRateAcquisition.prepare(delta, exporter: exporter, snapshot: snapshot, detections: detections).payloads
    }
}


extension HeartRateAcquisitionTests {
    private struct Fixture: Sendable {
        let journal: EventDeliveryJournal
        let sourceID: UUID
        let localID: UUID
        let transport: Transport
        let session: DeliveryTestSession
        let enrollmentIDs: [UUID]
        let acquisition: HeartRateAcquisition

        func collect(_ query: @Sendable (Date, QueryAnchor) async throws -> HeartRateAcquisition.Delta) async throws -> [UUID] {
            try await collectPage(query).eventIDs
        }

        func collectPage(
            _ query: @Sendable (Date, QueryAnchor) async throws -> HeartRateAcquisition.Delta
        ) async throws -> HeartRateAcquisition.Page {
            try await acquisition.collect(
                localID: localID,
                enrollmentIDs: enrollmentIDs,
                application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
                host: .init(operatingSystemVersion: "26.0"),
                query: query
            )
        }

        func using(_ journal: EventDeliveryJournal) throws -> Self {
            let client = Client(serverURL: try #require(URL(string: DeliveryFixture.scope.backend)), configuration: .trove, transport: transport)
            let acquisition = try HeartRateAcquisition(journal: journal, scope: DeliveryFixture.scope, client: client) {
                try await session.validate()
            }
            return .init(
                journal: journal,
                sourceID: sourceID,
                localID: localID,
                transport: transport,
                session: session,
                enrollmentIDs: enrollmentIDs,
                acquisition: acquisition
            )
        }

        func interruptCatchUp(_ interruption: Interruption) async {
            let task = Task {
                try await HeartRateAcquisition.catchUp {
                    try await collectPage { _, anchor in
                        if anchor == QueryAnchor() {
                            return delta([sample()])
                        }
                        #expect(anchor == nextAnchor)
                        switch interruption {
                        case .queryFailure: throw QueryFailure.unavailable
                        case .cancellation:
                            withUnsafeCurrentTask { $0?.cancel() }
                            return .init(added: [sample()], deletedIDs: [], nextAnchor: QueryAnchor(HKQueryAnchor(fromValue: 2)))
                        }
                    }
                }
            }
            switch await task.result {
            case .success: Issue.record("An interrupted page must not report successful catch-up.")
            case .failure(let error):
                switch interruption {
                case .queryFailure: #expect(error is QueryFailure)
                case .cancellation: #expect(error is CancellationError)
                }
            }
        }
    }

    private static let start = Date(timeIntervalSince1970: 1_787_000_000)
    private static var nextAnchor: QueryAnchor { QueryAnchor(HKQueryAnchor(fromValue: 1)) }

    private static func sample(type: HKQuantityTypeIdentifier = .heartRate, at date: Date = start) -> HKQuantitySample {
        HKQuantitySample(
            type: HKQuantityType(type),
            quantity: HKQuantity(unit: type == .heartRate ? .count().unitDivided(by: .minute()) : .count(), doubleValue: 72),
            start: date,
            end: date,
            metadata: [HKMetadataKeyTimeZone: "UTC"]
        )
    }

    private static func delta(_ samples: [HKQuantitySample]) -> HeartRateAcquisition.Delta {
        .init(added: samples, deletedIDs: [], nextAnchor: nextAnchor)
    }

    private static func withFixture(identifierRoot: String? = nil, _ operation: (Fixture, URL) async throws -> Void) async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let sourceID = UUID(), localID = UUID()
            let definition = try HeartRateAcquisition.queryDefinition(start: start)
            var binding = DeliveryFixture.binding(sourceID: sourceID, registrationID: localID)
            binding.identifierRoot = identifierRoot ?? DeliveryFixture.identifierRoot(sourceID)
            binding.eventIdentifierSystem = binding.identifierRoot + "/NamingSystem/grove-event-v0"
            let setup = try await journal.createSource(localID: localID, queryDefinition: definition)
            try await journal.confirmSource(binding, for: setup)
            let enrollments = [UUID(), UUID()]
            let transport = Transport(binding: binding, enrollmentIDs: enrollments)
            let session = DeliveryTestSession()
            let client = Client(serverURL: try #require(URL(string: DeliveryFixture.scope.backend)), configuration: .trove, transport: transport)
            let acquisition = try HeartRateAcquisition(journal: journal, scope: DeliveryFixture.scope, client: client) {
                try await session.validate()
            }
            try await operation(.init(
                journal: journal,
                sourceID: sourceID,
                localID: localID,
                transport: transport,
                session: session,
                enrollmentIDs: enrollments,
                acquisition: acquisition
            ), url)
        }
    }
}


extension HeartRateAcquisitionTests {
    private actor Transport: ClientTransport {
        let binding: Components.Schemas.ParticipantSource
        var plans: [Components.Schemas.ParticipantCollectionPlan]

        init(binding: Components.Schemas.ParticipantSource, enrollmentIDs: [UUID]) {
            self.binding = binding
            self.plans = enrollmentIDs.map { id in
                .init(enrollmentId: id.uuidString.lowercased(), stateVersion: 2, asOf: start.addingTimeInterval(10), windows: [
                    .init(
                        consentId: UUID().uuidString.lowercased(),
                        publicationId: UUID().uuidString.lowercased(),
                        revision: 1,
                        start: start,
                        requirements: [.init(profile: ParticipantCollectionSnapshot.heartRateProfile, sourceKind: .participantApp)]
                    )
                ])
            }
        }

        func withdrawFirstStudy() {
            plans[0].stateVersion += 1
            plans[0].windows = []
        }

        func setConsentStart(_ start: Date) {
            for index in plans.indices { plans[index].windows[0].start = start }
        }

        func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
            #expect(request.method == .get && body == nil)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(TroveDateTranscoder().encode(date))
            }
            let bytes: Data
            if operationID == "getParticipantCollectionPlan" {
                let plan = try #require(plans.first { request.path?.contains($0.enrollmentId) == true })
                bytes = try encoder.encode(plan)
            } else {
                #expect(operationID == "get/participant/sources/{sourceId}")
                bytes = try encoder.encode(binding)
            }
            return (.init(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(bytes))
        }
    }
}

#endif
