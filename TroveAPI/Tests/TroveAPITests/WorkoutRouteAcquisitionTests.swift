//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if canImport(HealthKit)

import CoreLocation
import Crypto
import Foundation
import GroveFHIRContract
import GroveFoundation
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
import Testing
@testable import TroveAPIClient
@testable import TroveHealthKit


struct WorkoutRouteAcquisitionTests {
    private typealias Fixture = HeartRatePlannerFixture
    private enum ReadFailure: Error { case interrupted }

    @Test
    func overlappingQueriesStageOneCompleteRouteForOnlyTheRouteConsent() async throws {
        let definition = try HealthKitQueryDefinition(stream: .workoutRoute, kind: .live, start: Fixture.liveStart)
        try await DeliveryFixture.withJournal(query: definition.encoded()) { journal, _ in
            try await Self.verifyCollection(in: journal)
        }
    }

    @Test
    func routeLargerThanConfiguredEventBudgetStagesWithoutMaterializingLocations() async throws {
        let definition = try HealthKitQueryDefinition(stream: .workoutRoute, kind: .live, start: Fixture.date(50))
        try await DeliveryFixture.withJournal(query: definition.encoded()) { journal, _ in
            _ = try await Fixture.retain(Self.plans(), in: journal)
            let count = 150_000
            let route = try WorkoutRouteFixture.sample(start: Fixture.date(25), end: Fixture.date(150), count: count)
            let acquisition = try HealthKitAcquisition(journal: journal, scope: DeliveryFixture.scope) {}
            let page = try await acquisition.collect(
                localID: DeliveryFixture.epoch,
                application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
                host: .init(operatingSystemVersion: "27.2")
            ) { _, _ in
                .init(added: [route], deletedIDs: [], nextAnchor: QueryAnchor(HKQueryAnchor(fromValue: 1))) { route in
                    try await HealthKitRecordingFile.workoutRoute(
                        route,
                        locations: RepeatedLocations(remaining: count),
                        relativePath: "recordings/route.csv",
                        maximumByteCount: 16 * 1024 * 1024
                    )
                }
            }
            let eventID = try #require(page.eventIDs.first)
            let attempt = try #require(try await journal.prepareAttempt(eventID))
            let file = try #require(attempt.recordings.first)
            let transfer = try #require(try await journal.recordingTransfer(for: file.id))
            #expect(transfer.commitment.declaration.content.sourceByteCount > EventDeliveryJournal.Limits().maximumPayloadBytes)
            #expect(transfer.commitment.declaration.content.encoding == .zstd)
            #expect(Int64(file.byteCount) < transfer.commitment.declaration.content.sourceByteCount)
            #expect(attempt.bytes.count < EventSubmissionLimits.maximumEventBytes)
            try await Self.verifyStoredRecording(attempt, in: journal)
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID).cursor != nil)
        }
    }

    @Test
    func routeTypeAndConsentAreIndependentOfWorkoutSummary() throws {
        let sample = try WorkoutRouteFixture.sample(start: Fixture.date(25), end: Fixture.date(150), count: 2)
        let plans = Self.plans()
        let snapshot = try ParticipantCollectionSnapshot(plans: plans, enrollmentIDs: plans.compactMap { UUID(uuidString: $0.enrollmentId) })
        #expect(HealthKitAcquisition.sampleType(for: HealthKitQueryDefinition.Stream.workoutRoute) == HKSeriesType.workoutRoute())
        let consents = try HealthKitAcquisition.consentIDs(for: sample, stream: .workoutRoute, snapshot: snapshot)
        #expect(consents == [UUID(uuidString: plans[0].windows[0].consentId)])
        #expect(throws: HealthKitAcquisition.AcquisitionError.unsupportedDelta) {
            try HealthKitAcquisition.consentIDs(for: sample, profile: .workout, snapshot: snapshot)
        }
    }

    @Test
    func excludedRouteDoesNotReadLocationsOrBlockLaterPages() async throws {
        let definition = try HealthKitQueryDefinition(stream: .workoutRoute, kind: .live, start: Fixture.date(50))
        try await DeliveryFixture.withJournal(query: definition.encoded()) { journal, _ in
            _ = try await Fixture.retain(Self.plans(), in: journal)
            let route = try WorkoutRouteFixture.sample(start: Fixture.date(200), end: Fixture.date(250), count: 2)
            let acquisition = try HealthKitAcquisition(journal: journal, scope: DeliveryFixture.scope) {}
            let page = try await acquisition.collect(
                localID: DeliveryFixture.epoch,
                application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
                host: .init(operatingSystemVersion: "27.2")
            ) { _, _ in
                .init(added: [route], deletedIDs: [], nextAnchor: QueryAnchor(HKQueryAnchor(fromValue: 1))) { _ in
                    Issue.record("An excluded route must not load companion locations")
                    throw ReadFailure.interrupted
                }
            }
            #expect(page.eventIDs.isEmpty && page.changeCount == 1 && !page.isCaughtUp)
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID).cursor != nil)
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
        }
    }

    @Test
    func failedRouteReadKeepsCursorAndQueueUnchanged() async throws {
        let definition = try HealthKitQueryDefinition(stream: .workoutRoute, kind: .live, start: Fixture.date(50))
        try await DeliveryFixture.withJournal(query: definition.encoded()) { journal, _ in
            _ = try await Fixture.retain(Self.plans(), in: journal)
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let route = try WorkoutRouteFixture.sample(start: Fixture.date(25), end: Fixture.date(150), count: 2)
            let acquisition = try HealthKitAcquisition(journal: journal, scope: DeliveryFixture.scope) {}
            await #expect(throws: ReadFailure.self) {
                try await acquisition.collect(
                    localID: DeliveryFixture.epoch,
                    application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
                    host: .init(operatingSystemVersion: "27.2")
                ) { query, _ in
                    #expect(query.stream == .workoutRoute)
                    return .init(added: [route], deletedIDs: [], nextAnchor: QueryAnchor(HKQueryAnchor(fromValue: 1))) { _ in
                        throw ReadFailure.interrupted
                    }
                }
            }
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID) == checkpoint)
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
        }
    }
}


extension WorkoutRouteAcquisitionTests {
    private struct RepeatedLocations: AsyncSequence, AsyncIteratorProtocol {
        typealias Element = CLLocation
        var remaining: Int

        func makeAsyncIterator() -> Self { self }

        mutating func next() async throws -> CLLocation? {
            guard remaining > 0 else {
                return nil
            }
            remaining -= 1
            return WorkoutRouteFixture.location(at: Fixture.date(90))
        }
    }

    private static func verifyCollection(in journal: EventDeliveryJournal) async throws {
        let plans = Self.plans()
        let state = try await Fixture.retain(plans, in: journal)
        let plan = try await journal.healthKitQueryPlan(for: DeliveryFixture.sourceID, state: state, at: Fixture.liveStart)
        let queries = plan.queries.filter { $0.definition.stream == .workoutRoute }
        #expect(queries.count == 2)
        let route = try WorkoutRouteFixture.sample(start: Fixture.date(25), end: Fixture.date(150), count: 2)
        // Location timestamps deliberately cover less than the complete HealthKit sample interval.
        let locations = [90.0, 100.0].map { WorkoutRouteFixture.location(at: Fixture.date($0)) }
        let acquisition = try HealthKitAcquisition(journal: journal, scope: DeliveryFixture.scope) {}
        var ids: [UUID] = [], bytes: Data?
        for query in queries {
            let page = try await acquisition.collect(
                localID: DeliveryFixture.epoch,
                application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
                host: .init(operatingSystemVersion: "27.2"),
                selection: .init(queryID: query.checkpoint.queryID, state: state)
            ) { _, anchor in
                #expect(anchor == QueryAnchor())
                return .init(
                    added: [route],
                    deletedIDs: [],
                    nextAnchor: QueryAnchor(HKQueryAnchor(fromValue: 1)),
                    readRoute: { route in
                        try await HealthKitRecordingFile.workoutRoute(
                            route, locations: Self.sequence(locations), relativePath: "recordings/route.csv", maximumByteCount: 4096
                        )
                    }
                )
            }
            ids += page.eventIDs
            let eventID = try #require(page.eventIDs.first)
            let attempt = try #require(try await journal.prepareAttempt(eventID))
            if let bytes { #expect(attempt.bytes == bytes) }
            bytes = attempt.bytes
            let file = try #require(attempt.recordings.first)
            #expect(attempt.recordings.count == 1)
            let transfer = try #require(try await journal.recordingTransfer(for: file.id))
            #expect(transfer.commitment.declaration.attachmentPath == file.relativePath)
            #expect(transfer.commitment.declaration.content.storedSHA256 == file.sha256)
            #expect(transfer.commitment.declaration.content.storedByteCount == Int64(file.byteCount))
            #expect(transfer.commitment.declaration.content.sourceByteCount >= Int64(file.byteCount))
            let targets = attempt.commitment.targetIntent.targets
            #expect(targets.count == 1 && targets.first?.consentID == UUID(uuidString: plans[0].windows[0].consentId))
            try verifyRecord(attempt.bytes, route: route)
            try await verifyStoredRecording(attempt, in: journal)
        }
        #expect(ids.count == 2 && Set(ids).count == 1)
    }

    private static func verifyStoredRecording(_ attempt: EventDeliveryJournal.Attempt, in journal: EventDeliveryJournal) async throws {
        let reference = try #require(attempt.recordings.first)
        let transfer = try #require(try await journal.recordingTransfer(for: reference.id))
        let content = transfer.commitment.declaration.content
        let file = try RecordingFile.stage(copying: await journal.recordingURL(for: reference.id), maximumByteCount: Int64(reference.byteCount))
        var storedHash = SHA256(), sourceHash = SHA256(), attachmentHash = Insecure.SHA1()
        var decodedBytes = 0
        func receive(_ bytes: Data) {
            sourceHash.update(data: bytes)
            attachmentHash.update(data: bytes)
            decodedBytes += bytes.count
        }
        try file.readChunks { storedHash.update(data: $0) }
        switch content.encoding {
        case .identity:
            try file.readChunks(receive)
        case .zstd:
            var decoder = try Zstd.StreamDecompressor(
                compressedByteCount: content.storedByteCount, decodedByteCount: content.sourceByteCount, maximumWindowByteCount: 8 * 1024 * 1024
            )
            try file.readChunks { try decoder.write($0, to: receive) }
            try decoder.finish()
        }
        #expect(storedHash.finalize().map { String(format: "%02x", $0) }.joined() == content.storedSHA256)
        #expect(sourceHash.finalize().map { String(format: "%02x", $0) }.joined() == content.sourceSHA256)
        #expect(Int64(decodedBytes) == content.sourceByteCount)
        let graph = try ExchangeGraph(validating: attempt.bytes, kind: .active)
        let document = try #require(graph.bundle.entry?.compactMap { entry in
            if case .documentReference(let value)? = entry.resource { value } else { nil }
        }.first)
        #expect(document.content.first?.attachment.hash?.value?.data() == Data(attachmentHash.finalize()))
        #expect(document.content.first?.attachment.size?.value?.integer == Int32(decodedBytes))
    }

    private static func verifyRecord(_ bytes: Data, route: HKWorkoutRoute) throws {
        let graph = try ExchangeGraph(validating: bytes, kind: .active)
        let document = try #require(graph.bundle.entry?.compactMap { entry in
            if case .documentReference(let value)? = entry.resource { value } else { nil }
        }.first)
        #expect(document.meta?.profile?.contains(Profile.healthkitRecordingDocument) == true)
        #expect(try document.context?.period?.start?.value?.asNSDate() == route.startDate)
        #expect(try document.context?.period?.end?.value?.asNSDate() == route.endDate)
        #expect(document.identifier?.contains { $0.value?.value?.string == route.uuid.uuidString.lowercased() } == true)
        #expect(document.content.count == 1 && document.content.first?.attachment.data == nil)
        #expect(document.content.first?.attachment.url?.value?.url.absoluteString == "recordings/route.csv")
    }

    private static func sequence(_ locations: [CLLocation]) -> AsyncThrowingStream<CLLocation, any Error> {
        AsyncThrowingStream { continuation in
            for location in locations { continuation.yield(location) }
            continuation.finish()
        }
    }

    static func plans() -> [Components.Schemas.ParticipantCollectionPlan] {
        var route = Fixture.plan(start: 50, end: 125), summary = Fixture.plan(start: 75, end: 175)
        route.windows[0].requirements[0].profile = CollectionObservationProfile.workout.rawValue
        route.windows[0].requirements[0].includeWorkoutRoutes = true
        summary.windows[0].requirements[0].profile = CollectionObservationProfile.workout.rawValue
        return [route, summary]
    }
}

#endif
