//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveFHIRContract
import GroveSensorKitFHIR
import ModelsR4
import Testing
@testable import TroveServer


struct FHIRSensorKitSourceEvidenceTests {
    @Test("The FHIR source code resolves to the exact native query stream", arguments:
        SensorKitCatalog.current.entries.map { ($0.sourceTypeCode, $0.sourceToken) }
    )
    func canonicalNativeStream(_ code: String, _ token: String) throws {
        let marker = Extension(url: Canonicals.sensorKitSourceTypeExtension, value: .code(FHIRPrimitive(FHIRString(code))))
        let evidence = try #require(try FHIRSourceTypeEvidence.extract([marker]))
        #expect(evidence.repository == .sensorKit)
        #expect(evidence.identifier == token)
    }

    @Test("An unknown or native-token marker cannot masquerade as a catalog FHIR code", arguments: [
        "unregistered-source", "SRSensor.onWristState"
    ])
    func rejectsUnknownCode(_ code: String) {
        let marker = Extension(url: Canonicals.sensorKitSourceTypeExtension, value: .code(FHIRPrimitive(FHIRString(code))))
        #expect(throws: (any Error).self) { try FHIRSourceTypeEvidence.extract([marker]) }
    }
}
