//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import TroveAPIClient


struct HeartRateQueryDefinitionTests {
    @Test(arguments: [-62_135_596_800.0, -1.0, 0.0, 253_402_300_799.0])
    func fullDateRangeHasStableCanonicalEncoding(seconds: Double) throws {
        let definition = try HeartRateQueryDefinition(kind: .live, start: Date(timeIntervalSince1970: seconds))
        #expect(try HeartRateQueryDefinition(bytes: definition.encoded()) == definition)
        #expect(definition.contains(definition.start))
        #expect(!definition.contains(definition.start.addingTimeInterval(-1)))
    }

    @Test
    func halfOpenBoundariesRemainExactForFractionalDates() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000.125), end = start.addingTimeInterval(0.5)
        let history = try HeartRateQueryDefinition(kind: .historical, start: start, end: end)
        let live = try HeartRateQueryDefinition(kind: .live, start: end)
        #expect(history.contains(start) && !history.contains(end))
        #expect(live.contains(end) && !live.contains(start))
        #expect(try HeartRateQueryDefinition(bytes: history.encoded()) == history)
        #expect(throws: HeartRateQueryDefinition.DefinitionError.self) { try HeartRateQueryDefinition(kind: .historical, start: end, end: start) }
        #expect(throws: HeartRateQueryDefinition.DefinitionError.self) { try HeartRateQueryDefinition(kind: .historical, start: start, end: start) }
        #expect(throws: HeartRateQueryDefinition.DefinitionError.self) { try HeartRateQueryDefinition(kind: .historical, start: start) }
        #expect(throws: HeartRateQueryDefinition.DefinitionError.self) { try HeartRateQueryDefinition(kind: .live, start: start, end: end) }
    }

    @Test(arguments: [-62_135_596_801.0, 253_402_300_800.0, Double.nan, Double.infinity])
    func invalidDatesAreRejected(seconds: Double) {
        #expect(throws: HeartRateQueryDefinition.DefinitionError.self) {
            try HeartRateQueryDefinition(kind: .live, start: Date(timeIntervalSince1970: seconds))
        }
    }

    @Test(arguments: ["version", "extra", "whitespace"])
    func unknownAndNoncanonicalDefinitionsCannotReuseAnAnchor(change: String) throws {
        let definition = try HeartRateQueryDefinition(kind: .live, start: Date(timeIntervalSince1970: 0))
        let original = try definition.encoded()
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        if change == "version" { object["version"] = 3 }
        if change == "extra" { object["unknown"] = true }
        let bytes = try change == "whitespace" ? original + Data([32]) : JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        #expect(throws: HeartRateQueryDefinition.DefinitionError.self) { try HeartRateQueryDefinition(bytes: bytes) }
    }
}
