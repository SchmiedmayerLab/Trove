// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import GroveSensorKitFHIR
import Testing
@testable import TroveAPIClient


struct SensorKitCollectionPolicyTests {
    private typealias Fixture = HeartRatePlannerFixture

    @Test
    func closedRosterUsesGeneratedProfilesAndRequiresExplicitOriginalRecordingScopes() throws {
        let sources = SensorKitCollectionCapabilities.sources
        #expect(sources.count == 16 && Set(sources.map(\.sourceToken)).count == sources.count)
        #expect(SensorKitCollectionCapabilities.outputs(for: "unknown-sensor").isEmpty)
        for source in sources {
            let entry = try #require(SensorKitCatalog.current.entry(sourceToken: source.sourceToken))
            for output in SensorKitCollectionCapabilities.outputs(for: source.sourceToken) {
                #expect((output.isRecording ? entry.rawProfiles : entry.structuredProfiles).contains(output.profile))
                let profile = try #require(CollectionObservationProfile(rawValue: output.profile))
                #expect(profile.nativeSources.isEmpty && profile.permitsNativeSource(source.sourceToken))
                #expect(!profile.permitsNativeSource(nil) && !profile.permitsNativeSource("unknown-sensor"))
                #expect(profile.permitsEffectiveTime(hasEnd: true))
                #expect(profile.permitsEffectiveTime(hasEnd: false) == (output.effective == .dateTimeOrPeriod))
                #expect(throws: HealthKitQueryDefinition.DefinitionError.invalidDefinition) { try HealthKitQueryDefinition.Stream(profile) }
            }
        }
        let recording = try #require(CollectionObservationProfile(rawValue: SensorKitContract.recordingDocumentProfile))
        #expect(recording.nativeSourceTypeIdentifier == nil && recording.sensorKitSources.count == 11)
    }

    @Test(arguments: SensorKitCollectionCapabilities.sources.map(\.sourceToken))
    func sensorOnlyAuthorityUsesExactSourceAndWholeOverlapWithoutStartingHealthKitQueries(source: String) async throws {
        let output = try #require(SensorKitCollectionCapabilities.outputs(for: source).first)
        let profile = try #require(CollectionObservationProfile(rawValue: output.profile))
        try await DeliveryFixture.withJournal { journal, _ in
            var plan = Fixture.plan(start: 100, end: 150)
            let template = plan.windows[0].requirements[0]
            plan.windows[0].requirements = SensorKitCollectionCapabilities.outputs(for: source).map { output in
                var requirement = template
                requirement.profile = output.profile
                requirement.sourceTypeIdentifier = source
                return requirement
            }
            let state = try await Fixture.retain([plan], in: journal)
            let snapshot = try #require(state.snapshot)
            #expect(snapshot.acquisitionStreams.isEmpty && snapshot.retainedStreams.isEmpty)
            #expect(snapshot.permitsSensorKitAcquisition)
            #expect(snapshot.queryStart(for: profile, sourceTypeIdentifier: source) == Fixture.date(100))
            #expect(snapshot.queryStart(for: profile, sourceTypeIdentifier: "unknown-sensor") == nil)
            let ids = try snapshot.consentIDs(profile: profile, start: Fixture.date(90), end: Fixture.date(160), sourceTypeIdentifier: source)
            #expect(ids == [try #require(UUID(uuidString: plan.windows[0].consentId))])
            #expect(try snapshot.consentIDs(
                profile: profile, start: Fixture.date(90), end: Fixture.date(160), sourceTypeIdentifier: "unknown-sensor"
            ).isEmpty)
            let checkpoint = try await journal.collectionCheckpoint(for: DeliveryFixture.sourceID, state: state, at: Fixture.liveStart)
            #expect(checkpoint.collectionRevision == state.revision)
            let withdrawn = try await journal.stopCollection(for: try #require(UUID(uuidString: plan.enrollmentId)))
            #expect(try withdrawn.snapshot?.active(at: Fixture.liveStart).permitsSensorKitAcquisition == false)
            await #expect(throws: ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized) {
                try await journal.collectionCheckpoint(for: DeliveryFixture.sourceID, state: withdrawn, at: Fixture.liveStart)
            }
        }
    }

    @Test(arguments: SensorKitCollectionCapabilities.sources.filter { !$0.requiredCompanionProfiles.isEmpty }.map(\.sourceToken))
    func hybridAuthorityMaySpanConsentsButDoesNotGrantTheCompanionToAnotherStudy(sourceToken: String) async throws {
        let source = try #require(SensorKitCollectionCapabilities.sources.first { $0.sourceToken == sourceToken })
        let outputs = SensorKitCollectionCapabilities.outputs(for: source.sourceToken)
        let primary = try #require(outputs.first { !$0.isRecording })
        let recording = try #require(outputs.first { $0.isRecording })
        #expect(primary.requiredCompanionProfiles == [recording.profile])
        #expect(recording.requiredCompanionProfiles == [primary.profile])
        try await DeliveryFixture.withJournal { journal, _ in
            var first = Fixture.plan(start: 100, end: 150)
            first.windows[0].requirements[0].profile = primary.profile
            first.windows[0].requirements[0].sourceTypeIdentifier = source.sourceToken
            let incomplete = try await Fixture.retain([first], in: journal)
            #expect(incomplete.snapshot?.permitsSensorKitAcquisition(sourceTypeIdentifier: source.sourceToken) == false)
            var second = first
            second.studyId = UUID().uuidString
            second.enrollmentId = UUID().uuidString
            second.windows[0].consentId = UUID().uuidString
            second.windows[0].requirements[0].profile = recording.profile
            let complete = try await Fixture.retain([first, second], in: journal)
            let snapshot = try #require(complete.snapshot)
            #expect(snapshot.permitsSensorKitAcquisition(sourceTypeIdentifier: source.sourceToken))
            for (output, plan) in [(primary, first), (recording, second)] {
                let profile = try #require(CollectionObservationProfile(rawValue: output.profile))
                let ids = try snapshot.consentIDs(
                    profile: profile, start: Fixture.date(90), end: Fixture.date(160), sourceTypeIdentifier: source.sourceToken
                )
                #expect(ids == [try #require(UUID(uuidString: plan.windows[0].consentId))])
            }
            let wrongSource = try #require(SensorKitCollectionCapabilities.sources.first { $0.observation == nil })
            #expect(!snapshot.permitsSensorKitAcquisition(sourceTypeIdentifier: wrongSource.sourceToken))
        }
    }
}
