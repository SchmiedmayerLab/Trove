// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

#if canImport(HealthKit)

import Foundation
import GroveFHIRContract
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
import ModelsR4
import Testing
@testable import TroveAPIClient
@testable import TroveHealthKit


struct ElectrocardiogramAcquisitionTests {
    private typealias Fixture = HeartRatePlannerFixture

    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        var isEmpty: Bool { lock.withLock { value == 0 } }
        func record() { lock.withLock { value += 1 } }
    }

    private static let stream: HealthKitQueryDefinition.Stream = {
        do { return try .init(.electrocardiogram) } catch { preconditionFailure("The ECG stream is a native capability") }
    }()

    private static func plan() -> Components.Schemas.ParticipantCollectionPlan {
        var plan = Fixture.plan(start: 100, end: 150)
        plan.windows[0].requirements[0].profile = stream.profile.rawValue
        plan.windows[0].requirements[0].sourceTypeIdentifier = stream.sourceTypeIdentifier
        return plan
    }

    private static func collect(
        _ ecg: HKElectrocardiogram,
        voltages: [HKElectrocardiogram.VoltageMeasurement],
        reads: Reads,
        in journal: EventDeliveryJournal,
        symptoms: [HKCategorySample]? = [], // swiftlint:disable:this discouraged_optional_collection
        deleted: [UUID] = []
    ) async throws -> HealthKitAcquisition.Page {
        let acquisition = try HealthKitAcquisition(journal: journal, scope: DeliveryFixture.scope) {}
        return try await acquisition.collect(
            localID: DeliveryFixture.epoch,
            application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
            host: .init(operatingSystemVersion: "27.2")
        ) { query, _ in
            #expect(query.stream == stream && query.usesOverlapPredicate)
            let read: @Sendable (HKElectrocardiogram) async throws -> HealthKitFHIRExporter.Record = { sample in
                reads.record()
                return .electrocardiogram(sample, voltages: voltages, symptoms: symptoms)
            }
            return .init(added: [ecg], deletedIDs: deleted, nextAnchor: QueryAnchor(HKQueryAnchor(fromValue: 1)), readElectrocardiogram: read)
        }
    }

    private static func observations(_ bytes: Data) throws -> [Observation] {
        try ExchangeGraph(validating: bytes, kind: .active).bundle.entry?.compactMap { entry in
            if case .observation(let value)? = entry.resource { value } else { nil }
        } ?? []
    }

    @Test
    func waveformAndAverageHeartRateAreOneConsentedEvent() async throws {
        let definition = try HealthKitQueryDefinition(stream: Self.stream, kind: .live, start: Fixture.liveStart)
        try await DeliveryFixture.withJournal(query: definition.encoded()) { journal, _ in
            let plan = Self.plan()
            _ = try await Fixture.retain([plan], in: journal)
            let recording = try ElectrocardiogramFixture.make(start: Fixture.date(110), end: Fixture.date(140))
            let reads = Reads()
            let page = try await Self.collect(recording.ecg, voltages: recording.voltages, reads: reads, in: journal)
            #expect(reads.count == 1 && page.eventIDs.count == 1)
            let eventID = try #require(page.eventIDs.first)
            let attempt = try #require(try await journal.prepareAttempt(eventID))
            let observations = try Self.observations(attempt.bytes)
            #expect(observations.count == 2)
            let waveform = try #require(observations.first { $0.component?.first.map { _ in true } == true })
            guard case .sampledData(let data)? = waveform.component?.first?.value else {
                Issue.record("The waveform carries its voltages as SampledData")
                return
            }
            #expect(data.data?.value?.string == "0.125 0.25 -0.125 0")
            let targets = attempt.commitment.targetIntent.targets
            #expect(targets.map(\.consentID) == [try #require(UUID(uuidString: plan.windows[0].consentId))])
            #expect(targets.first?.outputFullURLs.count == 2)
        }
    }

    @Test
    func symptomsRemainIndependentRecordsNamedByTheWaveform() async throws {
        let definition = try HealthKitQueryDefinition(stream: Self.stream, kind: .live, start: Fixture.liveStart)
        try await DeliveryFixture.withJournal(query: definition.encoded()) { journal, _ in
            _ = try await Fixture.retain([Self.plan()], in: journal)
            let recording = try ElectrocardiogramFixture.make(start: Fixture.date(110), end: Fixture.date(140), symptoms: true)
            let symptom = HKCategorySample(
                type: HKCategoryType(.chestTightnessOrPain),
                value: HKCategoryValueSeverity.mild.rawValue,
                start: Fixture.date(110),
                end: Fixture.date(140)
            )
            let page = try await Self.collect(recording.ecg, voltages: recording.voltages, reads: Reads(), in: journal, symptoms: [symptom])
            #expect(page.eventIDs.count == 1)
            let eventID = try #require(page.eventIDs.first)
            let attempt = try #require(try await journal.prepareAttempt(eventID))
            let observations = try Self.observations(attempt.bytes)
            let members = observations.compactMap(\.hasMember).flatMap(\.self)
            #expect(observations.count == 2 && members.count == 1 && members.first?.reference == nil && members.first?.identifier != nil)
            #expect(!String(decoding: attempt.bytes, as: UTF8.self).contains(symptom.uuid.uuidString.lowercased()))
        }
    }

    /// Symptom types need their own read authorization, and HealthKit does not reveal a denied read.
    @Test
    func anECGWhoseSymptomsCannotBeReadUploadsWithThemUnknown() async throws {
        let definition = try HealthKitQueryDefinition(stream: Self.stream, kind: .live, start: Fixture.liveStart)
        try await DeliveryFixture.withJournal(query: definition.encoded()) { journal, _ in
            _ = try await Fixture.retain([Self.plan()], in: journal)
            let recording = try ElectrocardiogramFixture.make(start: Fixture.date(110), end: Fixture.date(140), symptoms: true)
            let page = try await Self.collect(recording.ecg, voltages: recording.voltages, reads: Reads(), in: journal, symptoms: nil)
            #expect(page.eventIDs.count == 1)
            let eventID = try #require(page.eventIDs.first)
            let attempt = try #require(try await journal.prepareAttempt(eventID))
            let observations = try Self.observations(attempt.bytes)
            let members = observations.compactMap(\.hasMember).flatMap(\.self)
            #expect(observations.count == 2 && members.count == 1)
            let member = try #require(members.first)
            #expect(member.reference == nil && member.identifier == nil && member.type == nil)
            let reason = try #require(member.extension?.first)
            #expect(member.extension?.count == 1 && reason.url == Canonicals.dataAbsentReason)
            guard case .code(let code)? = reason.value else {
                Issue.record("The member states its data-absent reason as a code")
                return
            }
            #expect(code.value?.string == "unknown")
            #expect(attempt.commitment.targetIntent.targets.first?.outputFullURLs.count == 2)
        }
    }

    @Test
    func noSymptomForAPresentStatusMeansTheyCouldNotBeRead() {
        let symptom = HKCategorySample(
            type: HKCategoryType(.dizziness),
            value: HKCategoryValueSeverity.mild.rawValue,
            start: Fixture.date(110),
            end: Fixture.date(140)
        )
        #expect(HealthKitAcquisition.readableSymptoms([], status: .present) == nil)
        #expect(HealthKitAcquisition.readableSymptoms([symptom], status: .present) == [symptom])
        #expect(HealthKitAcquisition.readableSymptoms([], status: .none)?.isEmpty == true)
        #expect(HealthKitAcquisition.readableSymptoms([], status: .notSet)?.isEmpty == true)
    }

    @Test
    func anECGOutsideItsConsentIsNeitherReadNorStaged() async throws {
        let definition = try HealthKitQueryDefinition(stream: Self.stream, kind: .live, start: Fixture.liveStart)
        try await DeliveryFixture.withJournal(query: definition.encoded()) { journal, _ in
            _ = try await Fixture.retain([Self.plan()], in: journal)
            let recording = try ElectrocardiogramFixture.make(start: Fixture.date(160), end: Fixture.date(190))
            let reads = Reads()
            let page = try await Self.collect(recording.ecg, voltages: recording.voltages, reads: reads, in: journal)
            #expect(reads.isEmpty && page.eventIDs.isEmpty && !page.isCaughtUp)
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
        }
    }

    @Test
    func aDeletionReportRetractsTheECG() async throws {
        let definition = try HealthKitQueryDefinition(stream: Self.stream, kind: .live, start: Fixture.liveStart)
        try await DeliveryFixture.withJournal(query: definition.encoded()) { journal, _ in
            _ = try await Fixture.retain([Self.plan()], in: journal)
            let recording = try ElectrocardiogramFixture.make(start: Fixture.date(160), end: Fixture.date(190))
            let deleted = UUID()
            let page = try await Self.collect(recording.ecg, voltages: recording.voltages, reads: Reads(), in: journal, deleted: [deleted])
            let eventID = try #require(page.eventIDs.first)
            let attempt = try #require(try await journal.prepareAttempt(eventID))
            #expect(page.eventIDs.count == 1 && attempt.commitment.targetIntent.targets.isEmpty)
            #expect(try ExchangeRecord(validating: attempt.bytes).kind == .retraction)
        }
    }

    @Test
    func readingAnECGRequestsItsCorrelatedSymptomTypes() throws {
        let types = try HealthKitAcquisition.readTypes(for: Self.stream)
        #expect(types.first == HKObjectType.electrocardiogramType())
        #expect(Set(types.dropFirst()) == Set(HKElectrocardiogram.correlatedSymptomTypes.map(\.hkSampleType)))
        #expect(try HealthKitAcquisition.readTypes(for: .heartRate) == [HKQuantityType(.heartRate)])
    }
}

#endif
