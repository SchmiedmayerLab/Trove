//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import TroveServer


struct ProviderQueryCoverageTests {
    @Test
    func selectionKeepsEachProfilesOwnWindowsAndStableIdentity() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000), end = start.addingTimeInterval(100)
        let consent = UUID()
        let steps = try ProviderDemand(consentID: consent, profile: "steps", start: start, end: end)
        let early = try ProviderDemand(consentID: consent, profile: "energy", start: start, end: start.addingTimeInterval(40))
        let late = try ProviderDemand(consentID: consent, profile: "energy", start: start.addingTimeInterval(60), end: end)
        let selected = try ProviderQueryCoverage(demands: [steps, early, late], window: start..<end)
        let reordered = try ProviderQueryCoverage(demands: [late, steps, early, steps], window: start..<end)
        #expect(selected.selections.count == 3)
        #expect(try selected.digest == reordered.digest)
        let stepsOnly = try ProviderQueryCoverage(demands: [steps], window: start..<end)
        #expect(try selected.digest != stepsOnly.digest)
        let energy = try ProviderDemand(consentID: consent, profile: "energy", start: start, end: end)
        let windows = try selected.intersecting([energy]).map { $0.start..<($0.end) }
        #expect(windows == [early.start..<early.end, late.start..<late.end])
    }

    @Test
    func retainedSelectionDoesNotWidenOnRestartOrLaterConsent() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let prior = try ProviderDemand(consentID: UUID(), profile: "steps", start: start, end: start.addingTimeInterval(100))
        let coverage = try ProviderQueryCoverage(demands: [prior], window: prior.start..<prior.end)
        let recovered: ProviderQueryCoverage = try ProviderSQL.decode(coverage.encoded, maximumBytes: ProviderQueryCoverage.maximumBytes)
        let wider = try ProviderDemand(consentID: UUID(), profile: "steps", start: start.addingTimeInterval(-50), end: start.addingTimeInterval(150))
        let energy = try ProviderDemand(consentID: wider.consentID, profile: "energy", start: wider.start, end: wider.end)
        let selected = try recovered.intersecting([wider, energy])
        #expect(selected.count == 1)
        #expect(selected.first?.start == prior.start)
        #expect(selected.first?.end == prior.end)
        #expect(selected.first?.consentID == wider.consentID)
        #expect(try recovered.intersecting([]).isEmpty)
        #expect(try recovered.digest == coverage.digest)
    }
}
