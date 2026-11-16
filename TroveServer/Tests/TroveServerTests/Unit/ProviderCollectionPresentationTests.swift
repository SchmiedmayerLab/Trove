// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import GroveProviderFHIR
import Testing
import TroveAPITypes
@testable import TroveServer


struct ProviderCollectionPresentationTests {
    @Test
    func everyImplementedProviderMeasurementHasExplicitEnglishAndGermanScopeWording() throws {
        for provider in ProviderCapabilities.Provider.allCases {
            for source in ProviderCapabilities.sources(for: provider) where source.conversionSupport == .structured {
                for profile in source.outputProfiles {
                    let canonical = try #require(profile.value?.url.absoluteString)
                    for german in [false, true] {
                        let title = try CollectionScopePresentation.displayName(canonical, german: german, sourceTypeIdentifier: source.token)
                        #expect(!title.isEmpty && title != canonical && title != source.token)
                    }
                }
            }
        }
    }

    @Test
    func providerScopeDoesNotPromiseHealthKitSampleIdentifiers() throws {
        let requirement = CollectionRequirement(
            profile: CollectionObservationProfile.bodyWeight.rawValue,
            sourceKind: .serverWorker,
            providerRegistrationID: UUID(),
            sourceTypeIdentifier: "getmeas:1"
        )
        for language in ["en", "de"] {
            let markdown = try CollectionScopePresentation.markdown(requirements: [requirement], locale: language)
            #expect(!markdown.contains("HealthKit") && !markdown.contains("UUID"))
        }
    }
}
