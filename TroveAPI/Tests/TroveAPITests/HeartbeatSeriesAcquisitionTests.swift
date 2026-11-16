// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

#if canImport(HealthKit)

import Foundation
import GroveFHIRContract
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
import Testing
@testable import TroveAPIClient
@testable import TroveHealthKit


struct HeartbeatSeriesAcquisitionTests {
    private typealias Fixture = HeartRatePlannerFixture

    private struct Beats: AsyncSequence, AsyncIteratorProtocol {
        typealias Element = HealthKitFHIRExporter.Record.Heartbeat
        var count: Int
        var index = 0
        func makeAsyncIterator() -> Self { self }
        mutating func next() async throws -> Element? {
            guard index < count else {
                return nil
            }
            defer { index += 1 }
            return .init(timeSinceSeriesStart: 65 + Double(index) / 1_000, precededByGap: index.isMultiple(of: 3))
        }
    }

    private static func plans() throws -> [Components.Schemas.ParticipantCollectionPlan] {
        var series = Fixture.plan(start: 100, end: 150)
        series.windows[0].requirements[0].profile = CollectionObservationProfile.healthKitRecording.rawValue
        series.windows[0].requirements[0].sourceTypeIdentifier = SampleType.heartbeatSeries.hkSampleType.identifier
        var route = Fixture.plan(start: 100, end: 150)
        route.windows[0].requirements[0].profile = CollectionObservationProfile.workout.rawValue
        route.windows[0].requirements[0].includeWorkoutRoutes = true
        return [series, route]
    }

    private static func verify(
        _ attempt: EventDeliveryJournal.Attempt,
        declaration: Components.Schemas.RecordingTransferDeclaration,
        series: HKHeartbeatSeriesSample,
        consentID: UUID
    ) throws {
        let stored = try #require(attempt.recordings.first)
        #expect(declaration.profile == CollectionObservationProfile.healthKitRecording.rawValue)
        #expect(declaration.format == RegisteredRecordingFormat.beatIntervalSeries.rawValue)
        #expect(declaration.effectiveAt == series.startDate && declaration.effectiveEnd == series.endDate)
        #expect(declaration.content.storedSHA256 == stored.sha256 && declaration.content.storedByteCount == Int64(stored.byteCount))
        #expect(attempt.commitment.targetIntent.targets.map(\.consentID) == [consentID])
        let graph = try ExchangeGraph(validating: attempt.bytes, kind: .active)
        let document = try #require(graph.bundle.entry?.compactMap { entry in
            if case .documentReference(let value)? = entry.resource { value } else { nil }
        }.first)
        #expect(document.content.first?.attachment.data == nil)
        #expect(document.content.first?.attachment.url?.value?.url.relativeString == stored.relativePath)
        #expect(String(decoding: attempt.bytes, as: UTF8.self).contains(series.uuid.uuidString.lowercased()))
    }

    @Test
    func completeSeriesUsesItsOwnScopeAndKeepsGapFlagsInTheFileBackedUpload() async throws {
        let stream = try HealthKitQueryDefinition.Stream(
            .healthKitRecording, sourceTypeIdentifier: SampleType.heartbeatSeries.hkSampleType.identifier
        )
        let definition = try HealthKitQueryDefinition(stream: stream, kind: .live, start: Fixture.liveStart)
        try await DeliveryFixture.withJournal(query: definition.encoded()) { journal, _ in
            let plans = try Self.plans()
            _ = try await Fixture.retain(plans, in: journal)
            let series = try WorkoutRouteFixture.heartbeatSeries(start: Fixture.date(25), end: Fixture.date(160), count: 4)
            let acquisition = try HealthKitAcquisition(journal: journal, scope: DeliveryFixture.scope) {}
            let page = try await acquisition.collect(
                localID: DeliveryFixture.epoch,
                application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
                host: .init(operatingSystemVersion: "27.2")
            ) { query, _ in
                #expect(query.stream == stream && query.usesOverlapPredicate)
                return .init(
                    added: [series], deletedIDs: [], nextAnchor: QueryAnchor(HKQueryAnchor(fromValue: 1)), readHeartbeatSeries: { sample in
                        let recording = try await HealthKitRecordingFile.heartbeatSeries(
                            sample, beats: Beats(count: 4), relativePath: "recordings/beats.csv", maximumByteCount: 4_096
                        )
                        // Only this four-row synthetic source is collected for assertions, never production recordings.
                        var csv = Data()
                        try recording.file.readChunks { csv.append($0) }
                        let lines = String(decoding: csv, as: UTF8.self).split(separator: "\n")
                        #expect(lines.count == 5 && lines[1].hasSuffix(",1") && lines[2].hasSuffix(",0"))
                        return recording
                    }
                )
            }
            let eventID = try #require(page.eventIDs.first)
            let attempt = try #require(try await journal.prepareAttempt(eventID))
            let stored = try #require(attempt.recordings.first)
            let transfer = try #require(try await journal.recordingTransfer(for: stored.id))
            let consentID = try #require(UUID(uuidString: plans[0].windows[0].consentId))
            try Self.verify(
                attempt,
                declaration: transfer.commitment.declaration,
                series: series,
                consentID: consentID
            )
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID).cursor != nil)
        }
    }

    @Test(arguments: ["incomplete", "capacity", "cancelled", "route-only"])
    func failedOrUnselectedSeriesNeverAcknowledgesAPartialRecording(mode: String) async throws {
        let stream = try HealthKitQueryDefinition.Stream(
            .healthKitRecording, sourceTypeIdentifier: SampleType.heartbeatSeries.hkSampleType.identifier
        )
        let definition = try HealthKitQueryDefinition(stream: stream, kind: .live, start: Fixture.liveStart)
        try await DeliveryFixture.withJournal(query: definition.encoded()) { journal, _ in
            var plans = try Self.plans()
            if mode == "route-only" { plans.removeFirst() }
            _ = try await Fixture.retain(plans, in: journal)
            let before = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let series = try WorkoutRouteFixture.heartbeatSeries(start: Fixture.date(25), end: Fixture.date(160), count: 4)
            let acquisition = try HealthKitAcquisition(journal: journal, scope: DeliveryFixture.scope) {}
            let collect = {
                try await acquisition.collect(
                    localID: DeliveryFixture.epoch,
                    application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
                    host: .init(operatingSystemVersion: "27.2")
                ) { _, _ in
                    if mode == "route-only" { Issue.record("Workout-route authority must not query heartbeat data") }
                    return .init(
                        added: [series], deletedIDs: [], nextAnchor: QueryAnchor(HKQueryAnchor(fromValue: 1)), readHeartbeatSeries: { sample in
                            if mode == "route-only" { Issue.record("Workout-route authority must not read heartbeat data") }
                            if mode == "cancelled" { throw CancellationError() }
                            return try await HealthKitRecordingFile.heartbeatSeries(
                                sample,
                                beats: Beats(count: mode == "incomplete" ? 3 : 4),
                                relativePath: "recordings/beats.csv",
                                maximumByteCount: mode == "capacity" ? 1 : 4_096
                            )
                        }
                    )
                }
            }
            if mode == "route-only" {
                await #expect(throws: ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized) { try await collect() }
            } else {
                await #expect(throws: (any Error).self) { try await collect() }
            }
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID).cursor == before.cursor)
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
        }
    }
}

#endif
