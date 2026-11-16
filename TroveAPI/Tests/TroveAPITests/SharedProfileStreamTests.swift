// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import TroveAPIClient


struct SharedProfileStreamTests {
    private typealias Fixture = HeartRatePlannerFixture

    @Test
    func nativeStreamsSharingAProfileKeepSeparateAuthorityWindowsAndQueries() async throws {
        let profile = try #require(CollectionObservationProfile.allCases.first { $0.measurement?.id == "distance" })
        #expect(profile.nativeSources.count > 1)
        #expect(throws: HealthKitQueryDefinition.DefinitionError.invalidDefinition) { try HealthKitQueryDefinition.Stream(profile) }
        let firstSource = try #require(profile.nativeSources.first).sourceTypeIdentifier
        let secondSource = try #require(profile.nativeSources.last).sourceTypeIdentifier
        let first = try HealthKitQueryDefinition.Stream(profile, sourceTypeIdentifier: firstSource)
        let second = try HealthKitQueryDefinition.Stream(profile, sourceTypeIdentifier: secondSource)
        let definition = try HealthKitQueryDefinition(stream: first, kind: .live, start: Fixture.liveStart)
        try await DeliveryFixture.withJournal(query: definition.encoded()) { journal, _ in
            var firstPlan = Fixture.plan(start: -100)
            firstPlan.windows[0].requirements[0].profile = profile.rawValue
            firstPlan.windows[0].requirements[0].sourceTypeIdentifier = firstSource
            var secondPlan = Fixture.plan(start: -200)
            secondPlan.windows[0].requirements[0].profile = profile.rawValue
            secondPlan.windows[0].requirements[0].sourceTypeIdentifier = secondSource
            let state = try await Fixture.retain([firstPlan, secondPlan], in: journal)
            let snapshot = try #require(state.snapshot)
            #expect(Set(snapshot.acquisitionStreams) == [first, second])
            #expect(snapshot.queryStart(forStream: first) == Fixture.date(-100))
            #expect(snapshot.queryStart(forStream: second) == Fixture.date(-200))
            #expect(snapshot.queryStart(for: profile, sourceTypeIdentifier: firstSource) == Fixture.date(-100))
            #expect(snapshot.queryStart(for: profile, sourceTypeIdentifier: secondSource) == Fixture.date(-200))
            let consents = try snapshot.consentIDs(
                profile: profile, start: Fixture.date(-150), end: Fixture.date(-140), sourceTypeIdentifier: secondSource
            )
            #expect(consents == [try #require(UUID(uuidString: secondPlan.windows[0].consentId))])
            #expect(try snapshot.consentIDs(
                profile: profile, start: Fixture.date(-150), end: Fixture.date(-140), sourceTypeIdentifier: firstSource
            ).isEmpty)
            let queries = try await journal.healthKitQueryPlan(for: DeliveryFixture.sourceID, state: state, at: Fixture.liveStart)
            #expect(queries.queries.count == 4)
            #expect(Set(queries.queries.map { $0.definition.stream }) == [first, second])
            #expect(Set(queries.queries.map { $0.checkpoint.queryID }).count == 4)
        }
    }

    @Test
    func replayAuthorityIgnoresObservationTimeButChangesWithAcceptedPolicy() throws {
        let plan = Fixture.plan(start: -100)
        let enrollmentID = try #require(UUID(uuidString: plan.enrollmentId))
        let original = try ParticipantCollectionSnapshot(plans: [plan], enrollmentIDs: [enrollmentID])
        var refreshed = plan
        refreshed.asOf += 60
        refreshed.title = .init([.enUS: "Updated display title"])
        let unchanged = try ParticipantCollectionSnapshot(plans: [refreshed], enrollmentIDs: [enrollmentID])
        #expect(try original.authorityFingerprint() == unchanged.authorityFingerprint())
        var extended = refreshed
        extended.windows[0].requirements[0].start -= 100
        extended.stateVersion += 1
        let changed = try ParticipantCollectionSnapshot(plans: [extended], enrollmentIDs: [enrollmentID])
        #expect(try original.authorityFingerprint() != changed.authorityFingerprint())
        let withdrawn = try ParticipantCollectionSnapshot(plans: [], enrollmentIDs: [])
        #expect(try original.authorityFingerprint() != withdrawn.authorityFingerprint())
    }

    @Test(arguments: [(-10.0, 0.0, true), (0.0, 0.0, true), (49.0, 50.0, true), (50.0, 60.0, false), (-10.0, -1.0, false)])
    func batchPreflightIncludesBoundaryPointsWithoutGrantingUnselectedOutputs(start: Double, end: Double, selected: Bool) throws {
        let plan = Fixture.plan(start: 100, end: 150)
        let enrollmentID = try #require(UUID(uuidString: plan.enrollmentId))
        let snapshot = try ParticipantCollectionSnapshot(plans: [plan], enrollmentIDs: [enrollmentID])
        let source = try #require(CollectionObservationProfile.heartRate.nativeSourceTypeIdentifier)
        #expect(try snapshot.maySelect(
            profile: .heartRate,
            sourceTypeIdentifier: source,
            effectiveStart: Fixture.date(100 + start),
            effectiveEnd: Fixture.date(100 + end)
        ) == selected)
        #expect(try !snapshot.maySelect(
            profile: .bodyWeight,
            sourceTypeIdentifier: source,
            effectiveStart: Fixture.date(100 + start),
            effectiveEnd: Fixture.date(100 + end)
        ))
    }
}
