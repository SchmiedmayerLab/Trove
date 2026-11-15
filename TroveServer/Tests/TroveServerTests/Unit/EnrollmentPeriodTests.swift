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


struct EnrollmentPeriodTests {
    @Test(arguments: [
        ("2023-08-31T19:00:00Z", "2024-02-29T20:00:00Z", 6, 0),
        ("2024-08-31T19:00:00Z", "2025-02-28T20:00:00Z", 6, 0),
        ("2026-03-01T20:00:00Z", "2026-04-01T19:00:00Z", 1, 0),
        ("2026-03-07T20:00:00Z", "2026-03-08T19:00:00Z", 0, 1)
    ])
    func durationUsesDeclaredCalendarAndZone(start: String, end: String, months: Int, days: Int) throws {
        let policy = EnrollmentPeriod(calendar: .gregorian, timeZone: "America/Los_Angeles", duration: .init(month: months, day: days))
        #expect(try policy.resolve(at: Self.date(start)) == Self.date(end))
    }

    @Test
    func fixedCloseCapsDurationAndRejectsJoiningAtTheBoundary() throws {
        let start = try Self.date("2026-01-01T00:00:00Z"), end = try Self.date("2026-02-01T00:00:00Z")
        let period = EnrollmentPeriod(calendar: .gregorian, timeZone: "UTC", duration: .init(month: 6), end: end)
        #expect(try period.resolve(at: start) == end)
        #expect(throws: ServerError.self) { try period.resolve(at: end) }
        #expect(try EnrollmentPeriod.ongoing.resolve(at: start) == nil)
    }

    @Test(arguments: ["empty", "zero", "negative", "overflow", "zone", "invalid-end"])
    func invalidPolicyCannotBecomeOngoing(kind: String) throws {
        var period = EnrollmentPeriod.ongoing
        switch kind {
        case "empty": period.duration = .init()
        case "zero": period.duration = .init(day: 0)
        case "negative": period.duration = .init(day: -1)
        case "overflow": period.duration = .init(year: Int.max)
        case "zone": period.timeZone = "PST"
        default: period.end = Date(timeIntervalSince1970: .nan)
        }
        #expect(throws: ServerError.self) { try period.resolve(at: Self.date("2026-01-01T00:00:00Z")) }
    }

    @Test
    func publicationCarriesExactRuleInArchiveAndConsent() throws {
        let end = try TroveDateTranscoder().decode("2027-01-01T00:00:00.123456Z")
        let period = EnrollmentPeriod(calendar: .gregorian, timeZone: "UTC", duration: .init(month: 6), end: end)
        let policy = try PublishedCollectionPolicy.compile(studyID: UUID(), revision: 1, requirements: [], enrollmentPeriod: period)
        let object = try #require(JSONSerialization.jsonObject(with: policy.archiveBytes()) as? [String: Any])
        let archived = try #require(object["enrollmentPeriod"] as? [String: Any])
        #expect(archived["end"] as? String == "2027-01-01T00:00:00.123456Z")
        let english = try EnrollmentPeriodPresentation.markdown(period, locale: "en-US")
        #expect(english.contains("6 months") && english.contains("2027-01-01T00:00:00.123456Z"))
        #expect(english.contains("earlier end") && english.contains("does not extend"))
        #expect(try EnrollmentPeriodPresentation.markdown(period, locale: "de-DE").contains("6 Monate"))
        #expect(throws: ServerError.self) { try EnrollmentPeriodPresentation.markdown(period, locale: "fr-FR") }
    }
}


extension EnrollmentPeriodTests {
    private static func date(_ value: String) throws -> Date { try TroveDateTranscoder().decode(value) }
}
