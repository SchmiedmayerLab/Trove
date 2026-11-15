//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import Trove
import TroveSensorKit


@Suite
struct SensorDataConfigurationTests {
    @Test(arguments: [nil, "NO", "$(TROVE_SENSORKIT_ENABLED)"])
    func disabledDeploymentDoesNotCreateReaders(enabled: String?) {
        #expect(SensorDataConfiguration.selectedSources(
            enabled: enabled, privacyPolicyURL: "https://research.example/privacy", identifiers: ["onWrist"]
        ).isEmpty)
    }

    @Test(arguments: [nil, "", "http://research.example/privacy", "https://$(TROVE_SENSORKIT_PRIVACY_POLICY_URL)", "https://user@research.example"])
    func missingOrInvalidPrivacyPolicyDoesNotEnableSensors(url: String?) {
        #expect(SensorDataConfiguration.selectedSources(enabled: "YES", privacyPolicyURL: url, identifiers: ["onWrist"]).isEmpty)
    }

    @Test(arguments: [["onWrist", "onWrist"], ["onWrist", "unknown"]])
    func invalidSourceSelectionDoesNotPartiallyEnableSensors(_ identifiers: [String]) {
        #expect(SensorDataConfiguration.selectedSources(
            enabled: "YES", privacyPolicyURL: "https://research.example/privacy", identifiers: identifiers
        ).isEmpty)
    }

    @Test
    func configuredSelectionPreservesExactSourcesAndOrder() {
        #expect(SensorDataConfiguration.selectedSources(
            enabled: "YES", privacyPolicyURL: "https://research.example/privacy", identifiers: ["visits", "onWrist"]
        ) == [.visits, .onWrist])
    }
}
