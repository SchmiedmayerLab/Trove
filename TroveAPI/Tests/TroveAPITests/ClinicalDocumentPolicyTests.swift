// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import GroveHealthKit
import Testing
@testable import TroveAPIClient


#if canImport(HealthKit)
import HealthKit


#endif


struct ClinicalDocumentPolicyTests {
    private typealias Fixture = HeartRatePlannerFixture

    private static var streams: [HealthKitQueryDefinition.Stream] {
        HealthKitQueryDefinition.Stream.allCases.filter { $0.timeBasis != .measurementTime }
    }

    @Test
    func sourceTimeBasesAreClosedAndSharedDocumentProfilesRemainSourceBound() throws {
        #expect(Self.streams.count == 10)
        #expect(Self.streams.filter { $0.timeBasis == .clinicalRecordDownload }.count == 9)
        #expect(CollectionTimeBasis.required(profile: CollectionObservationProfile.heartRate.rawValue, sourceTypeIdentifier: nil) == .measurementTime)
        #expect(CollectionTimeBasis.required(
            profile: CollectionObservationProfile.healthKitRecording.rawValue, sourceTypeIdentifier: "unknown"
        ) == .measurementTime)
        #expect(throws: HealthKitQueryDefinition.DefinitionError.invalidDefinition) {
            try HealthKitQueryDefinition.Stream(.healthKitRecording)
        }
    }

    @Test(arguments: streams)
    func acceptedSourceDateBasisSelectsWholeDocumentsButCannotBeReinterpretedAsCareDates(stream: HealthKitQueryDefinition.Stream) async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            var plan = Fixture.plan(start: 100, end: 150)
            plan.windows[0].requirements[0].profile = stream.profile.rawValue
            plan.windows[0].requirements[0].sourceTypeIdentifier = stream.sourceTypeIdentifier
            plan.windows[0].requirements[0].timeBasis = stream.timeBasis
            let snapshot = try #require(await Fixture.retain([plan], in: journal).snapshot)
            let id = try #require(UUID(uuidString: plan.windows[0].consentId))
            #expect(try snapshot.consentIDs(
                profile: stream.profile,
                start: Fixture.date(90),
                end: Fixture.date(160),
                sourceTypeIdentifier: stream.sourceTypeIdentifier,
                timeBasis: stream.timeBasis
            ) == [id])
            #expect(try snapshot.consentIDs(
                profile: stream.profile,
                start: Fixture.date(110),
                end: Fixture.date(110),
                sourceTypeIdentifier: stream.sourceTypeIdentifier,
                timeBasis: stream.timeBasis
            ) == [id])
            #expect(try snapshot.consentIDs(
                profile: stream.profile, start: Fixture.date(110), end: Fixture.date(110), sourceTypeIdentifier: stream.sourceTypeIdentifier
            ).isEmpty)
            #expect(try snapshot.consentIDs(
                profile: stream.profile,
                start: Fixture.date(150),
                end: Fixture.date(150),
                sourceTypeIdentifier: stream.sourceTypeIdentifier,
                timeBasis: stream.timeBasis
            ).isEmpty)
            var invalid = plan
            invalid.windows[0].requirements[0].timeBasis = nil
            #expect(throws: ParticipantCollectionSnapshot.CollectionError.unsupportedRequirement) {
                try ParticipantCollectionSnapshot(plans: [invalid], enrollmentIDs: [try #require(UUID(uuidString: invalid.enrollmentId))])
            }
        }
    }
}
