//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPIServer
@testable import TroveServer


struct CollectionMeasurementWindowTests {
    @Test(arguments: [
        ("2024-08-31T19:00:00Z", "2024-02-29T20:00:00Z", 6, 0),
        ("2025-08-31T19:00:00Z", "2025-02-28T20:00:00Z", 6, 0),
        ("2026-04-01T19:00:00Z", "2026-03-01T20:00:00Z", 1, 0),
        ("2026-03-08T19:00:00Z", "2026-03-07T20:00:00Z", 0, 1)
    ])
    func relativeWindowsUseCalendarMonthsAndLocalTime(anchor: String, expected: String, months: Int, days: Int) throws {
        let window = CollectionMeasurementWindow(
            calendar: .gregorian,
            timeZone: "America/Los_Angeles",
            start: .last(.init(_type: .last, components: .init(month: months, day: days)))
        )
        let resolved = try window.resolve(at: (try Self.date(anchor)))
        #expect(resolved.start == (try Self.date(expected)))
        #expect(resolved.end == nil)
    }

    @Test
    func resolvedHistoryIsRetainedAndNeverRecomputedAtUpload() throws {
        let window = CollectionMeasurementWindow(
            calendar: .gregorian, timeZone: "UTC", start: .last(.init(_type: .last, components: .init(month: 6)))
        )
        let requirement = CollectionRequirement(
            profile: CollectionRequirement.supportedProfile, sourceKind: .participantApp, measurementWindow: window
        )
        let study = UUID(), anchor = (try Self.date("2024-08-31T19:00:00Z"))
        let policy = try PublishedCollectionPolicy.compile(studyID: study, revision: 1, requirements: [requirement])
        let accepted = try AcceptedCollectionScope(requirements: [requirement], acceptedAt: anchor)
        let retained = try JSONDecoder().decode(AcceptedCollectionScope.self, from: JSONEncoder().encode(accepted))
        let lower = (try Self.date("2024-02-29T19:00:00Z"))
        let resolved = try policy.resolvedRequirements(studyID: study, revision: 1, acceptedAt: anchor, scope: retained, adoptionEnd: nil)
        #expect(resolved[0].start == lower)
        #expect(try policy.resolvedRequirements(
            studyID: study, revision: 1, acceptedAt: anchor.addingTimeInterval(86_400), scope: retained, adoptionEnd: nil
        )[0].start == lower)
        #expect(throws: ServerError.self) {
            try policy.resolvedRequirements(studyID: study, revision: 1, acceptedAt: anchor, scope: nil, adoptionEnd: nil)
        }
    }

    @Test
    func explicitRangeHasInclusiveStartAndExclusiveEndIndependentOfAcceptance() throws {
        let lower = (try Self.date("2024-01-01T00:00:00Z")), upper = (try Self.date("2024-07-01T00:00:00Z"))
        let requirement = CollectionRequirement(
            profile: CollectionRequirement.supportedProfile,
            sourceKind: .participantApp,
            measurementWindow: .init(calendar: .gregorian, timeZone: "UTC", start: .absolute(.init(_type: .absolute, date: lower)), end: upper)
        )
        let anchor = (try Self.date("2025-01-01T00:00:00Z")), study = UUID()
        let scope = try AcceptedCollectionScope(requirements: [requirement], acceptedAt: anchor)
        let policy = try PublishedCollectionPolicy.compile(studyID: study, revision: 1, requirements: [requirement])
        let requirements = try policy.resolvedRequirements(studyID: study, revision: 1, acceptedAt: anchor, scope: scope, adoptionEnd: nil)
        let resolved = try #require(requirements.first)
        #expect(resolved.contains(lower))
        #expect(!resolved.contains(lower.addingTimeInterval(-0.001)))
        #expect(!resolved.contains(upper))
    }

    @Test(arguments: ["zone", "empty", "negative", "overflow", "backwards"])
    func invalidWindowsCannotBecomeAllHistory(kind: String) throws {
        var window = CollectionMeasurementWindow(calendar: .gregorian, timeZone: "UTC")
        switch kind {
        case "zone": window.timeZone = "PST"
        case "empty": window.start = .last(.init(_type: .last, components: .init(month: 0)))
        case "negative": window.start = .last(.init(_type: .last, components: .init(month: -6)))
        case "overflow": window.start = .last(.init(_type: .last, components: .init(year: Int.max)))
        default:
            window.start = .absolute(.init(_type: .absolute, date: (try Self.date("2024-07-01T00:00:00Z"))))
            window.end = (try Self.date("2024-01-01T00:00:00Z"))
        }
        #expect(throws: ServerError.self) { try window.validate() }
    }

    @Test
    func archivedPolicyUsesExactUTCDateStrings() throws {
        let start = try TroveDateTranscoder().decode("2024-01-01T00:00:00.123456Z")
        let end = try TroveDateTranscoder().decode("2024-07-01T00:00:00.654321Z")
        let requirement = CollectionRequirement(
            profile: CollectionRequirement.supportedProfile,
            sourceKind: .participantApp,
            measurementWindow: .init(calendar: .gregorian, timeZone: "UTC", start: .absolute(.init(_type: .absolute, date: start)), end: end)
        )
        let policy = try PublishedCollectionPolicy.compile(studyID: UUID(), revision: 1, requirements: [requirement])
        let json = try #require(JSONSerialization.jsonObject(with: policy.archiveBytes()) as? [String: Any])
        let requirements = try #require(json["requirements"] as? [[String: Any]])
        let window = try #require(requirements.first?["measurementWindow"] as? [String: Any])
        let strategy = try #require(window["start"] as? [String: Any])
        #expect(strategy["date"] as? String == "2024-01-01T00:00:00.123456Z")
        #expect(window["end"] as? String == "2024-07-01T00:00:00.654321Z")
        let disclosure = try CollectionScopePresentation.markdown(requirements: [requirement], locale: "en-US")
        #expect(disclosure.contains("2024-01-01T00:00:00.123456Z"))
        #expect(disclosure.contains("2024-07-01T00:00:00.654321Z"))
    }

    @Test
    func disclosureIsLocalizedAndUnsupportedLocalesCannotFallBack() throws {
        let requirement = CollectionRequirement(
            profile: CollectionRequirement.supportedProfile,
            sourceKind: .participantApp,
            measurementWindow: .init(calendar: .gregorian, timeZone: "UTC", start: .last(.init(_type: .last, components: .init(month: 6))))
        )
        #expect(try CollectionScopePresentation.markdown(requirements: [requirement], locale: "en-US").contains("6 months"))
        #expect(try CollectionScopePresentation.markdown(requirements: [requirement], locale: "de-DE").contains("6 Monate"))
        #expect(try CollectionScopePresentation.markdown(requirements: [requirement], locale: "en-US").contains("HealthKit sample identifier (UUID)"))
        #expect(try CollectionScopePresentation.markdown(requirements: [requirement], locale: "de-DE").contains("HealthKit-Kennung (UUID)"))
        #expect(throws: ServerError.self) { try CollectionScopePresentation.markdown(requirements: [requirement], locale: "fr-FR") }
    }
}


extension CollectionMeasurementWindowTests {
    private static func date(_ value: String) throws -> Date {
        // These are fixed UTC fixture instants, not locale-sensitive input.
        try #require(ISO8601DateFormatter().date(from: value))
    }
}
