//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPIClient


struct ParticipantCollectionSnapshotTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 100)

    @Test
    func newQueryStartsAtEarliestEligibleWindowAndNotTheCurrentClock() throws {
        let first = Self.plan()
        var second = Self.plan()
        second.windows[0].start += 1
        second.windows[0].requirements[0].start += 1
        #expect(try Self.snapshot([first, second]).heartRateQueryStart == Self.start)
        #expect(try Self.snapshot([second, first]).heartRateQueryStart == Self.start)
        second.windows[0].requirements = []
        #expect(try Self.snapshot([second]).heartRateQueryStart == nil)
    }

    @Test
    func emptyHistoricalWindowsCannotWidenTheInitialQuery() throws {
        var plan = Self.plan()
        plan.windows[0].end = Self.start
        plan.windows[0].requirements[0].end = Self.start
        var next = Self.plan().windows[0]
        next.revision = 2
        next.start = Self.start
        next.requirements = []
        plan.windows.append(next)
        #expect(try Self.snapshot([plan]).heartRateQueryStart == nil)
    }

    @Test
    func onePointSelectsTwoConsentsWithoutDuplicatingThePoint() throws {
        let first = Self.plan(), second = Self.plan()
        let snapshot = try Self.snapshot([first, second])
        #expect(snapshot.permitsHeartRateAcquisition)
        let selected = try snapshot.consentIDs(forHeartRateAt: Self.start)
        #expect(Set(selected.map(\.uuidString).map { $0.lowercased() }) == Set([first.windows[0].consentId, second.windows[0].consentId]))
    }

    @Test
    func adoptionUsesExclusiveEndAndInclusiveStartAtMicrosecondPrecision() throws {
        var plan = Self.plan()
        let boundary = Self.start.addingTimeInterval(0.123456)
        plan.windows[0].end = boundary
        plan.windows[0].requirements[0].end = boundary
        var next = Self.plan().windows[0]
        next.start = boundary
        next.requirements[0].start = boundary
        next.revision = 2
        plan.windows.append(next)
        let snapshot = try Self.snapshot([plan])
        let before = try snapshot.consentIDs(forHeartRateAt: boundary.addingTimeInterval(-0.000001))
        let exact = try snapshot.consentIDs(forHeartRateAt: boundary)
        #expect(before == [try #require(UUID(uuidString: plan.windows[0].consentId))])
        #expect(exact == [try #require(UUID(uuidString: next.consentId))])
        #expect(try snapshot.consentIDs(forHeartRateAt: Self.start.addingTimeInterval(-0.000001)).isEmpty)
    }

    @Test
    func sameInstantAdoptionLeavesEarlierWindowEmpty() throws {
        var plan = Self.plan()
        plan.windows[0].end = Self.start
        plan.windows[0].requirements[0].end = Self.start
        var next = Self.plan().windows[0]
        next.revision = 2
        plan.windows.append(next)
        let snapshot = try Self.snapshot([plan])
        #expect(try snapshot.consentIDs(forHeartRateAt: Self.start) == [try #require(UUID(uuidString: next.consentId))])
    }

    @Test
    func adoptedHistorySelectsOneConsentPerStudyAndKeepsTheHistoricalQueryStart() throws {
        var plan = Self.plan()
        let boundary = Self.start.addingTimeInterval(1)
        let historical = Self.start.addingTimeInterval(-10_000)
        plan.windows[0].end = boundary
        plan.windows[0].requirements[0].end = boundary
        plan.windows[0].requirements[0].start = historical
        var next = Self.plan().windows[0]
        next.start = boundary
        next.revision = 2
        next.requirements[0].start = historical
        plan.windows.append(next)
        var other = Self.plan()
        other.windows[0].requirements[0].start = historical
        let snapshot = try Self.snapshot([plan, other])
        #expect(snapshot.heartRateQueryStart == historical)
        let expected = try Set([next.consentId, other.windows[0].consentId].map { try #require(UUID(uuidString: $0)) })
        #expect(try Set(snapshot.consentIDs(forHeartRateAt: historical)) == expected)
        #expect(try snapshot.consentIDs(forHeartRateAt: historical.addingTimeInterval(-0.001)).isEmpty)
    }

    @Test
    func withdrawalFromOneStudyPreservesOnlyTheOtherStudySelection() throws {
        var withdrawn = Self.plan()
        let active = Self.plan()
        let before = try Self.snapshot([withdrawn, active])
        withdrawn.stateVersion += 1
        withdrawn.windows = []
        let after = try Self.snapshot([withdrawn, active])
        #expect(!before.hasSameAuthority(as: after))
        #expect(after.permitsHeartRateAcquisition)
        #expect(try after.consentIDs(forHeartRateAt: Self.start) == [try #require(UUID(uuidString: active.windows[0].consentId))])
    }

    @Test
    func historicalPermissionDoesNotEnableAnotherQuery() throws {
        var plan = Self.plan()
        let boundary = Self.start.addingTimeInterval(1)
        plan.windows[0].end = boundary
        plan.windows[0].requirements[0].end = boundary
        var next = Self.plan().windows[0]
        next.start = boundary
        next.requirements[0].start = boundary
        next.revision = 2
        next.requirements = []
        plan.windows.append(next)
        let snapshot = try Self.snapshot([plan])
        #expect(!snapshot.permitsHeartRateAcquisition)
        #expect(try snapshot.consentIDs(forHeartRateAt: Self.start).count == 1)
        #expect(try snapshot.consentIDs(forHeartRateAt: boundary).isEmpty)
    }

    @Test
    func refreshIgnoresLaterObservationTimeButNotStateChanges() throws {
        var plan = Self.plan()
        let before = try Self.snapshot([plan])
        plan.asOf += 1
        #expect(before.hasSameAuthority(as: try Self.snapshot([plan])))
        plan.stateVersion += 1
        #expect(!before.hasSameAuthority(as: try Self.snapshot([plan])))
        plan.stateVersion -= 1
        plan.asOf -= 2
        #expect(!before.hasSameAuthority(as: try Self.snapshot([plan])))
    }

    @Test(arguments: ["enrollment", "consent", "publication", "version", "revision", "time", "end", "duplicate", "gap"])
    func invalidPlansCannotProducePartialAuthority(field: String) throws {
        var plan = Self.plan()
        switch field {
        case "enrollment": plan.enrollmentId = "invalid"
        case "consent": plan.windows[0].consentId = "invalid"
        case "publication": plan.windows[0].publicationId = "invalid"
        case "version": plan.stateVersion = 0
        case "revision": plan.windows[0].revision = 0
        case "time": plan.windows[0].start = Date(timeIntervalSince1970: .nan)
        case "end": plan.windows[0].end = Self.start
        case "duplicate": plan.windows.append(plan.windows[0])
        default:
            plan.windows[0].end = Self.start
            plan.windows[0].requirements[0].end = Self.start
            var next = Self.plan().windows[0]
            next.start += 1
            next.revision = 2
            plan.windows.append(next)
        }
        let valid = Self.plan()
        let requested = [UUID(uuidString: plan.enrollmentId) ?? UUID(), try #require(UUID(uuidString: valid.enrollmentId))]
        #expect(throws: ParticipantCollectionSnapshot.CollectionError.invalidPlan) {
            try ParticipantCollectionSnapshot(plans: [plan, valid], enrollmentIDs: requested)
        }
    }

    @Test(arguments: ["study", "title", "blank-title", "long-title"])
    func invalidSavedDetailsCannotBeRetained(field: String) throws {
        var plan = Self.plan()
        switch field {
        case "study": plan.studyId = "invalid"
        case "title": plan.title = .init()
        case "blank-title": plan.title = .init([.enUS: " \n\t"])
        default: plan.title = .init([.enUS: String(repeating: "a", count: 4097)])
        }
        #expect(throws: ParticipantCollectionSnapshot.CollectionError.invalidPlan) { try Self.snapshot([plan]) }
    }

    @Test
    func unsupportedProfileDoesNotBecomeAnEmptyPermission() throws {
        var plan = Self.plan()
        plan.windows[0].requirements[0].profile = "https://unknown.test/profile"
        #expect(throws: ParticipantCollectionSnapshot.CollectionError.unsupportedRequirement) { try Self.snapshot([plan]) }
    }

    @Test
    func missingDuplicateAndUnrequestedResponsesAreRejected() throws {
        let plan = Self.plan()
        let id = try #require(UUID(uuidString: plan.enrollmentId))
        #expect(throws: ParticipantCollectionSnapshot.CollectionError.invalidPlan) {
            try ParticipantCollectionSnapshot(plans: [], enrollmentIDs: [id])
        }
        #expect(throws: ParticipantCollectionSnapshot.CollectionError.invalidPlan) {
            try ParticipantCollectionSnapshot(plans: [plan, plan], enrollmentIDs: [id, id])
        }
        #expect(throws: ParticipantCollectionSnapshot.CollectionError.invalidPlan) {
            try ParticipantCollectionSnapshot(plans: [plan], enrollmentIDs: [UUID()])
        }
        #expect(try ParticipantCollectionSnapshot(plans: [], enrollmentIDs: []).permitsHeartRateAcquisition == false)
    }
}


extension ParticipantCollectionSnapshotTests {
    private static func plan() -> Components.Schemas.ParticipantCollectionPlan {
        .init(
            enrollmentId: UUID().uuidString.lowercased(),
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

    private static func snapshot(_ plans: [Components.Schemas.ParticipantCollectionPlan]) throws -> ParticipantCollectionSnapshot {
        try ParticipantCollectionSnapshot(plans: plans, enrollmentIDs: plans.map { try #require(UUID(uuidString: $0.enrollmentId)) })
    }
}


extension ParticipantCollectionSnapshotTests {
    @Test(arguments: [(-60.0, 60.0, true), (-60, 0, false), (60, 180, true), (120, 180, false), (-60, 180, true)])
    func sleepSelectionIncludesWholeIntervalsAndSharesOneRecordAcrossStudies(start: Double, end: Double, included: Bool) throws {
        var first = Self.plan(), second = Self.plan()
        for index in [0, 1] {
            var plan = index == 0 ? first : second
            plan.windows[0].requirements.append(.init(
                profile: ParticipantCollectionSnapshot.sleepStageProfile,
                sourceKind: .participantApp,
                start: Self.start,
                end: Self.start.addingTimeInterval(120)
            ))
            if index == 0 { first = plan } else { second = plan }
        }
        let snapshot = try Self.snapshot([first, second])
        #expect(snapshot.permitsSleepAcquisition && snapshot.permitsHeartRateAcquisition)
        #expect(snapshot.sleepQueryStart == Self.start)
        let consents = try snapshot.consentIDs(
            forSleepStarting: Self.start.addingTimeInterval(start), ending: Self.start.addingTimeInterval(end)
        )
        let expected = included ? [first.windows[0].consentId, second.windows[0].consentId] : []
        #expect(Set(consents.map { $0.uuidString.lowercased() }) == Set(expected))
    }

    @Test
    func duplicateSleepRequirementCannotWidenAuthority() throws {
        var plan = Self.plan()
        let sleep = Components.Schemas.CollectionPlanRequirement(
            profile: ParticipantCollectionSnapshot.sleepStageProfile, sourceKind: .participantApp, start: Self.start
        )
        plan.windows[0].requirements = [sleep, sleep]
        #expect(throws: ParticipantCollectionSnapshot.CollectionError.invalidPlan) { try Self.snapshot([plan]) }
    }
}
