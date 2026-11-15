// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import TroveAPITypes
@testable import TroveServer


struct ProviderStatusDisclosureTests {
    @Test(arguments: [
        ProviderConnectionService.CollectionAttempt.Outcome.scheduled, .deferred, .accepted, .noCurrentDemand,
        .transientFailure, .capacityBlocked, .sourceBlocked, .authorizationChanged
    ])
    func attemptDisclosureRetainsExactSourceAndOnlySanitizedStatus(_ outcome: ProviderConnectionService.CollectionAttempt.Outcome) throws {
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let attempt = ProviderConnectionService.CollectionAttempt(sourceTypeIdentifier: "getmeas:1", outcome: outcome, nextAttempt: time)
        let wire = Components.Schemas.ProviderCollectionAttempt(attempt)
        let encoded = try JSONEncoder().encode(wire)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == ["sourceTypeIdentifier", "outcome", "nextAttempt"])
        #expect(object["sourceTypeIdentifier"] as? String == "getmeas:1")
        #expect(object["outcome"] as? String == outcome.rawValue)
        #expect(try JSONDecoder().decode(Components.Schemas.ProviderCollectionAttempt.self, from: encoded).nextAttempt == time)
    }

    @Test
    func absentAttemptDoesNotInventACollectionCompletenessClaim() throws {
        var status = ProviderConnectionService.Status(
            id: UUID(),
            registrationID: UUID(),
            sourceID: UUID(),
            state: .active,
            generation: 1,
            lastAttempt: nil,
            lastSuccessfulFetch: nil,
            acceptedThrough: nil,
            requiresReauthorization: false
        )
        let absent = try JSONEncoder().encode(Components.Schemas.ProviderConnection(status))
        let absentObject = try #require(JSONSerialization.jsonObject(with: absent) as? [String: Any])
        #expect(absentObject["collectionAttempt"] == nil)
        status.collectionAttempt = .init(
            sourceTypeIdentifier: "getmeas:1", outcome: .capacityBlocked, nextAttempt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let present = Components.Schemas.ProviderConnection(status)
        #expect(present.state == .active && present.collectionAttempt?.outcome == .capacityBlocked)
        #expect(present.acceptedThrough == nil)
    }
}
