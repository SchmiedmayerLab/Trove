// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import GroveFHIRContract
import Testing
@testable import TroveAPIClient


struct QuantityCollectionCatalogTests {
    @Test
    func scalarSelectionRetainsTheGeneratedContractAndRejectsOtherShapes() throws {
        let quantities = CollectionObservationProfile.allCases.filter { $0.quantitySource != nil }
        #expect(quantities.count > 100)
        #expect(Set(quantities.map(\.rawValue)).count == quantities.count)
        for profile in quantities {
            let source = try #require(profile.quantitySource)
            let contract = try #require(profile.measurement)
            #expect(source.guideStatus == .supported && contract.valueShape == .quantity)
            #expect(CollectionObservationProfile(rawValue: profile.rawValue) == profile)
            #expect(try JSONDecoder().decode(CollectionObservationProfile.self, from: JSONEncoder().encode(profile)) == profile)
            for source in profile.nativeSources {
                #expect(profile.localizedNativeTitle(language: "en", sourceTypeIdentifier: source.sourceTypeIdentifier)?.isEmpty == false)
                #expect(profile.localizedNativeTitle(language: "de", sourceTypeIdentifier: source.sourceTypeIdentifier)?.isEmpty == false)
            }
        }
        for id in ["workout-segment", "date-of-birth"] {
            if let profile = FHIRMeasurementCatalog.measurement(id: id)?.profile.value?.url.absoluteString {
                #expect(CollectionObservationProfile(rawValue: profile) == nil)
            }
        }
        #expect(CollectionObservationProfile(rawValue: CollectionObservationProfile.bodyWeight.rawValue + " ") == nil)
        #expect(throws: (any Error).self) {
            try HealthKitQueryDefinition(profile: .onWrist, kind: .live, start: Date(timeIntervalSince1970: 50))
        }
    }

    @Test
    func allQuantityStreamsKeepIndependentCanonicalDefinitionsAndTemporalPredicates() throws {
        let start = Date(timeIntervalSince1970: 50), end = Date(timeIntervalSince1970: 100)
        let streams = HealthKitQueryDefinition.Stream.allCases.filter { $0.profile.quantitySource != nil }
        #expect(Set(streams.map(\.rawValue)).count == streams.count)
        for stream in streams {
            let query = try HealthKitQueryDefinition(stream: stream, kind: .historical, start: start, end: end)
            #expect(try HealthKitQueryDefinition(bytes: query.encoded()) == query)
            if query.usesOverlapPredicate {
                #expect(query.contains(start.addingTimeInterval(-10), ending: start.addingTimeInterval(1)))
                #expect(!query.contains(start.addingTimeInterval(-10), ending: start))
                #expect(!query.contains(end, ending: end.addingTimeInterval(10)))
                #expect(query.contains(start) == stream.profile.permitsEffectiveTime(hasEnd: false))
            } else {
                #expect(query.contains(start) && !query.contains(end))
                #expect(!query.contains(start, ending: end))
            }
        }
    }
}
