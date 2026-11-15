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
import ModelsR4
import Testing
@testable import TroveAPIClient
@testable import TroveHealthKit


struct HealthKitAcquisitionTests {
    private enum Interruption: CaseIterable { case queryFailure, cancellation }
    private enum QueryFailure: Error { case unavailable }

    @Test(arguments: ["https://trove.test/events", "urn:uuid:19e5294b-859b-4670-8c58-9f34f5417cd1"])
    func groveConversionStagesOneEventForTwoStudiesAndRestoresExactBytes(identifierRoot: String) async throws {
        try await Self.withFixture(identifierRoot: identifierRoot) { fixture, url in
            let sample = Self.sample()
            let ids = try await fixture.collect { _, anchor in
                #expect(anchor == QueryAnchor())
                return Self.delta([sample])
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
            let native = try #require((observations.first?["identifier"] as? [[String: Any]])?.first { $0["type"] == nil })
            #expect(native["value"] as? String == sample.uuid.uuidString.lowercased())
            #expect(native["system"] as? String == identifierRoot + "/NamingSystem/healthkit-native-record")
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
            await #expect(throws: EventDeliveryJournal.JournalError.staleCheckpoint) {
                try await fixture.collect { _, _ in
                    try await fixture.journal.stopCollection(for: #require(fixture.enrollmentIDs.first))
                    return Self.delta([Self.sample()])
                }
            }
            #expect(try await fixture.journal.checkpoint(for: fixture.sourceID).cursor == before.cursor)
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
            await #expect(throws: HealthKitAcquisition.AcquisitionError.authenticationRequired) {
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
            await #expect(throws: HealthKitAcquisition.AcquisitionError.unsupportedDelta) {
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
            await fixture.authority.setConsentStart(boundary)
            try await fixture.retainPlans()
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
            try connection.execute(
                "UPDATE acquisition_query SET cursor = x'00' WHERE local_id IN (SELECT local_id FROM source_state WHERE source_id = ?)",
                [.text(fixture.sourceID.uuidString.lowercased())]
            )
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
                let progress = try await HealthKitAcquisition.catchUp {
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
    func mixedDeltaRetractsTheWholeSourceRecordWithoutCopyingSamplesOrConsentTargets() async throws {
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
            let activeRecord = try ExchangeRecord(validating: addition.bytes)
            let retractedRecord = try ExchangeRecord(validating: deletion.bytes)
            #expect(activeRecord.sourceRecord == retractedRecord.sourceRecord)
            #expect(activeRecord.version != retractedRecord.version)
            #expect(retractedRecord.outputFullURLs.isEmpty)
            #expect(deletion.commitment.targetIntent.targets.isEmpty)
            #expect(retracted.bundle.entry?.count == 3)
            let observation = try #require(active.bundle.entry?.compactMap { entry in
                if case .observation(let value)? = entry.resource {
                    return value
                }
                return nil
            }.first)
            try Self.verifyRetraction(retracted, of: observation)
            let native = try #require(observation.identifier?.first { $0.type == nil })
            #expect(native.value?.value?.string == sample.uuid.uuidString.lowercased())
            let provenance = try #require(retracted.bundle.entry?.compactMap { entry -> Provenance? in
                if case .provenance(let value)? = entry.resource { value } else { nil }
            }.first)
            let disclosed = try #require(provenance.target.first?.extension?.first { $0.url == Canonicals.retractionTargetNativeIdentifier })
            #expect(disclosed.value == .identifier(native))
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
            let record = try ExchangeRecord(validating: attempt.bytes)
            #expect(record.kind == .retraction && record.outputFullURLs.isEmpty)
            #expect(record.sharedNodeFullURLs.count == 2)
        }
    }
}


extension HealthKitAcquisitionTests {
    @Test
    func exportBeforeFailedStagingRestoresExactActiveAndRetractionBytes() async throws {
        try await Self.withFixture { fixture, url in
            let sample = Self.sample()
            let delta = HealthKitAcquisition.Delta(added: [sample], deletedIDs: [sample.uuid], nextAnchor: Self.nextAnchor)
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


extension HealthKitAcquisitionTests {
    private static func verifyRetraction(_ retracted: ExchangeGraph, of observation: Observation) throws {
        let provenance = try #require(retracted.bundle.entry?.compactMap { entry in
            if case .provenance(let value)? = entry.resource {
                return value
            }
            return nil
        }.first)
        let identities = try (observation.identifier ?? []).filter { $0.type != nil }.map(RoledIdentifier.init)
        #expect(try provenance.target.map { try RoledIdentifier(#require($0.identifier)) } == identities.filter { $0.role == .sourceRecord })
        let source = try #require(provenance.entity?.first?.what.identifier)
        #expect(try RoledIdentifier(source) == identities.first { $0.role == .sourceRecord })
        guard case .period(let occurred)? = provenance.occurred else {
            Issue.record("Unknown deletion time must not become a fabricated exact timestamp")
            return
        }
        #expect(occurred.start == nil && occurred.end?.value != nil)
    }

    private static func uncommittedPayloads(
        _ delta: HealthKitAcquisition.Delta, fixture: Fixture, journal: EventDeliveryJournal
    ) async throws -> [EventDeliveryJournal.Payload] {
        let snapshot = try await ParticipantCollectionSnapshot(plans: fixture.authority.plans, enrollmentIDs: fixture.enrollmentIDs)
        let checkpoint = try await journal.checkpoint(for: fixture.sourceID)
        let exporter = try await HealthKitAcquisition.exporter(
            source: fixture.authority.binding.source,
            privacy: journal.identityScope(for: fixture.sourceID),
            application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
            host: .init(operatingSystemVersion: "27.2")
        )
        let configuration = try HealthKitAcquisition.conversionConfiguration(
            application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"), host: .init(operatingSystemVersion: "27.2")
        )
        let acquisition = try fixture.using(journal).acquisition
        return try await acquisition.preparePage(
            delta, checkpoint: checkpoint, snapshot: snapshot, exporter: exporter, configuration: configuration
        ).payloads
    }
}


extension HealthKitAcquisitionTests {
    private struct Fixture: Sendable {
        let journal: EventDeliveryJournal
        let sourceID: UUID
        let localID: UUID
        let authority: Authority
        let session: DeliveryTestSession
        let enrollmentIDs: [UUID]
        let acquisition: HealthKitAcquisition

        func collect(_ query: @Sendable (HealthKitQueryDefinition, QueryAnchor) async throws -> HealthKitAcquisition.Delta) async throws -> [UUID] {
            try await collectPage(query).eventIDs
        }

        func collectPage(
            _ query: @Sendable (HealthKitQueryDefinition, QueryAnchor) async throws -> HealthKitAcquisition.Delta
        ) async throws -> HealthKitAcquisition.Page {
            try await acquisition.collect(
                localID: localID,
                application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
                host: .init(operatingSystemVersion: "26.0"),
                query: query
            )
        }

        func retainPlans() async throws {
            let snapshot = try await ParticipantCollectionSnapshot(plans: authority.plans, enrollmentIDs: enrollmentIDs)
            try await journal.retainCollectionSnapshot(snapshot, replacing: journal.collectionState())
        }

        func using(_ journal: EventDeliveryJournal) throws -> Self {
            let acquisition = try HealthKitAcquisition(journal: journal, scope: DeliveryFixture.scope) {
                try await session.validate()
            }
            return .init(
                journal: journal,
                sourceID: sourceID,
                localID: localID,
                authority: authority,
                session: session,
                enrollmentIDs: enrollmentIDs,
                acquisition: acquisition
            )
        }

        func interruptCatchUp(_ interruption: Interruption) async {
            let task = _Concurrency.Task {
                try await HealthKitAcquisition.catchUp {
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

    private static func delta(_ samples: [HKQuantitySample]) -> HealthKitAcquisition.Delta {
        .init(added: samples, deletedIDs: [], nextAnchor: nextAnchor)
    }

    private static func withFixture(identifierRoot: String? = nil, _ operation: (Fixture, URL) async throws -> Void) async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let sourceID = UUID(), localID = UUID()
            let definition = try HealthKitAcquisition.queryDefinition(start: start)
            var binding = DeliveryFixture.binding(sourceID: sourceID, registrationID: localID)
            binding.source.identifierRoot = identifierRoot ?? DeliveryFixture.identifierRoot(sourceID)
            binding.source.eventIdentifierSystem = binding.source.identifierRoot + "/NamingSystem/grove-record-version-v0/\(localID.uuidString.lowercased())/1"
            binding.source.repositoryScope.system = binding.source.identifierRoot + "/repository"
            let setup = try await journal.createSource(localID: localID, queryDefinition: definition)
            try await journal.confirmSource(binding, for: setup, identityKey: DeliveryFixture.identityKey)
            let enrollments = [UUID(), UUID()]
            let authority = Authority(binding: binding, enrollmentIDs: enrollments)
            let snapshot = try await ParticipantCollectionSnapshot(plans: authority.plans, enrollmentIDs: enrollments)
            try await journal.retainCollectionSnapshot(snapshot, replacing: journal.collectionState())
            let session = DeliveryTestSession()
            let acquisition = try HealthKitAcquisition(journal: journal, scope: DeliveryFixture.scope) {
                try await session.validate()
            }
            try await operation(.init(
                journal: journal,
                sourceID: sourceID,
                localID: localID,
                authority: authority,
                session: session,
                enrollmentIDs: enrollments,
                acquisition: acquisition
            ), url)
        }
    }
}


extension HealthKitAcquisitionTests {
    private actor Authority {
        let binding: Components.Schemas.ParticipantSourceRegistration
        var plans: [Components.Schemas.ParticipantCollectionPlan]

        init(binding: Components.Schemas.ParticipantSourceRegistration, enrollmentIDs: [UUID]) {
            self.binding = binding
            self.plans = enrollmentIDs.map { id in
                .init(
                    enrollmentId: id.uuidString.lowercased(),
                    studyId: UUID().uuidString,
                    title: .init([.enUS: "Saved Study"]),
                    stateVersion: 2,
                    asOf: start.addingTimeInterval(10),
                    windows: [
                        .init(
                            consentId: UUID().uuidString.lowercased(),
                            publicationId: UUID().uuidString.lowercased(),
                            revision: 1,
                            start: start,
                            requirements: [.init(profile: ParticipantCollectionSnapshot.heartRateProfile, sourceKind: .participantApp, start: start)]
                        )
                    ]
                )
            }
        }

        func setConsentStart(_ start: Date) {
            for index in plans.indices {
                plans[index].stateVersion += 1
                plans[index].windows[0].start = start
                plans[index].windows[0].requirements[0].start = start
            }
        }
    }
}

#endif
