// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import TroveAPITypes
@testable import TroveServer


struct SensorKitCollectionCapabilityTests {
    @Test
    func sensorCapabilitiesExposeOnlyImplementedExactScopesWithConsentTranslations() throws {
        let values = try NativeCollectionCapabilities.values().filter { $0.repositoryKind == .sensorkit }
        #expect(values.count == 19)
        #expect(values.filter { $0.isOriginalRecording == true }.count == 10)
        for value in values {
            let outputs = SensorKitCollectionCapabilities.outputs(for: value.sourceTypeIdentifier)
            let output = try #require(outputs.first { $0.profile == value.profile })
            #expect(!value.supportsWorkoutRoutes && value.isOriginalRecording == output.isRecording)
            #expect(value.requiredCompanionProfiles == output.requiredCompanionProfiles)
            #expect(value.effectiveTime == (output.effective == .period ? .interval : .pointOrInterval))
            for german in [false, true] {
                let title = try CollectionScopePresentation.displayName(
                    value.profile, german: german, sourceTypeIdentifier: value.sourceTypeIdentifier
                )
                #expect(!title.isEmpty && title != value.profile && title != value.sourceTypeIdentifier)
                #expect(title == (german ? value.displayNameGerman : value.displayNameEnglish))
                let requirement = CollectionRequirement(
                    profile: value.profile, sourceKind: .participantApp, sourceTypeIdentifier: value.sourceTypeIdentifier
                )
                let text = try CollectionScopePresentation.markdown(requirements: [requirement], locale: german ? "de" : "en")
                #expect(text.contains(title) && !text.contains("HealthKit") && !text.contains("UUID"))
            }
        }
    }
}
