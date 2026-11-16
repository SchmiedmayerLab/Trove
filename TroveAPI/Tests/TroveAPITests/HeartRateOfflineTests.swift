//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if canImport(HealthKit)

import Foundation
import GroveHealthKit
import HealthKit
import Testing
@testable import TroveAPIClient
@testable import TroveHealthKit


struct HeartRateOfflineTests {
    private static let oldest = Date(timeIntervalSince1970: -62_135_596_800)

    @Test(arguments: [-62_135_596_800.0, -1.0, 0.0, 253_402_300_799.0])
    func querySupportsTheCompleteAcceptedDateRange(seconds: Double) throws {
        let definition = try HealthKitAcquisition.queryDefinition(start: Date(timeIntervalSince1970: seconds))
        let decoded = try HealthKitQueryDefinition(bytes: definition)
        #expect(decoded.start.timeIntervalSince1970 == seconds)
    }

    @Test(arguments: [-62_135_596_801.0, 253_402_300_800.0, Double.nan, Double.infinity])
    func malformedDatesCannotCreateAQuery(seconds: Double) {
        #expect(throws: HealthKitAcquisition.AcquisitionError.invalidQueryDefinition) {
            try HealthKitAcquisition.queryDefinition(start: Date(timeIntervalSince1970: seconds))
        }
    }

    @Test
    func missingAcceptedPlanDoesNotReadHealthKit() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let localID = try await Self.register(journal)
            let acquisition = try HealthKitAcquisition(journal: journal, scope: DeliveryFixture.scope, validateSession: {})
            await #expect(throws: ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized) {
                try await acquisition.prepareQueryDefinition()
            }
            await #expect(throws: ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized) {
                try await acquisition.collect(
                    localID: localID,
                    application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
                    host: .init(operatingSystemVersion: "27.2")
                ) { _, _ in
                    Issue.record("A missing accepted plan must not reach HealthKit")
                    return Self.emptyDelta()
                }
            }
        }
    }

    @Test
    func oldAcceptedHistoryRemainsUsableAfterRestartWithoutAnyNetworkClient() async throws {
        try await DeliveryFixture.withJournal { journal, url in
            let localID = try await Self.register(journal)
            try await Self.retainPlan(journal)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting)
            let acquisition = try HealthKitAcquisition(journal: reopened, scope: DeliveryFixture.scope, validateSession: {})
            #expect(try await acquisition.prepareQueryDefinition(at: Self.oldest) == HealthKitAcquisition.queryDefinition(start: Self.oldest))
            let page = try await acquisition.collect(
                localID: localID,
                application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
                host: .init(operatingSystemVersion: "27.2")
            ) { start, anchor in
                #expect(start.start == Self.oldest && anchor == QueryAnchor())
                return Self.emptyDelta()
            }
            #expect(page.isCaughtUp && page.eventIDs.isEmpty)
            await reopened.close()
        }
    }

    @Test
    func knownRevocationDuringLocalQueryPreventsStaging() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let localID = try await Self.register(journal)
            try await Self.retainPlan(journal)
            let setup = try await journal.sourceSetup(for: localID)
            let binding = try #require(setup.binding)
            let sourceID = try #require(UUID(uuidString: binding.source.id))
            let acquisition = try HealthKitAcquisition(journal: journal, scope: DeliveryFixture.scope, validateSession: {})
            await #expect(throws: DeliveryJournalError.sourceRevoked) {
                try await acquisition.collect(
                    localID: localID,
                    application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
                    host: .init(operatingSystemVersion: "27.2")
                ) { _, _ in
                    var revoked = binding
                    revoked.installation.revokedAt = revoked.installation.createdAt
                    try await journal.confirmSource(revoked, for: setup)
                    return Self.emptyDelta()
                }
            }
            #expect(try await journal.checkpoint(for: sourceID).cursor == nil)
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
        }
    }
}


extension HeartRateOfflineTests {
    private static func register(_ journal: EventDeliveryJournal) async throws -> UUID {
        let localID = UUID()
        let setup = try await journal.createSource(localID: localID, queryDefinition: HealthKitAcquisition.queryDefinition(start: oldest))
        try await journal.confirmSource(
            DeliveryFixture.binding(sourceID: UUID(), registrationID: localID), for: setup, identityKey: DeliveryFixture.identityKey
        )
        return localID
    }

    private static func retainPlan(_ journal: EventDeliveryJournal) async throws {
        let id = UUID()
        let accepted = Date(timeIntervalSinceReferenceDate: 100)
        let plan = Components.Schemas.ParticipantCollectionPlan(
            enrollmentId: id.uuidString.lowercased(),
            studyId: UUID().uuidString,
            title: .init([.enUS: "Saved Study"]),
            stateVersion: 2,
            asOf: accepted,
            windows: [
                .init(
                    consentId: UUID().uuidString.lowercased(),
                    publicationId: UUID().uuidString.lowercased(),
                    revision: 1,
                    start: accepted,
                    requirements: [.init(profile: ParticipantCollectionSnapshot.heartRateProfile, sourceKind: .participantApp, start: oldest)]
                )
            ]
        )
        try await journal.retainCollectionSnapshot(.init(plans: [plan], enrollmentIDs: [id]), replacing: journal.collectionState())
    }

    private static func emptyDelta() -> HealthKitAcquisition.Delta {
        .init(added: [], deletedIDs: [], nextAnchor: QueryAnchor(HKQueryAnchor(fromValue: 1)))
    }
}

#endif
