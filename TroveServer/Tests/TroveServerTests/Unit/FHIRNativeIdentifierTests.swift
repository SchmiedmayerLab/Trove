//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import ModelsR4
import Testing
@testable import TroveServer


struct FHIRNativeIdentifierTests {
    @Test
    func clearUUIDSurvivesActiveAndRetractionProjectionWithoutReplacingOpaqueIdentity() throws {
        let original = try fixture()
        let before = try FHIRPointProjection.project(validatedBytes: original, validatorIdentity: "test-only")
        let bytes = try NativeIdentifierFixture.adding([
            ["system": NativeIdentifierFixture.system, "value": NativeIdentifierFixture.uuid]
        ], to: original)
        let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-only")
        #expect(event.outputs[0].sourceRecordIdentifier == before.outputs[0].sourceRecordIdentifier)
        #expect(event.outputs[0].sourceOutputIdentifier == before.outputs[0].sourceOutputIdentifier)
        #expect(event.rawBytes == bytes)
        #expect(event.nativeRecordIdentifiers == [.init(system: NativeIdentifierFixture.system, value: NativeIdentifierFixture.uuid)])
        #expect(event.deploymentIdentifiers.systems == before.deploymentIdentifiers.systems)
        let identifier = Identifier(
            system: NativeIdentifierFixture.system.asFHIRURIPrimitive(), value: NativeIdentifierFixture.uuid.asFHIRStringPrimitive()
        )
        let deleted = try RetractionEventFixture.bytes(
            activeBytes: bytes, nativeIdentifier: identifier, retractionSystem: IdentifierSystem("urn:trove:test:record-retraction")
        )
        let retraction = try FHIRPointProjection.project(validatedBytes: deleted, validatorIdentity: "test-only")
        #expect(retraction.nativeRecordIdentifiers == event.nativeRecordIdentifiers)
        #expect(retraction.retraction?.sourceRecordIdentifier == before.outputs[0].sourceRecordIdentifier)
        #expect(retraction.rawBytes == deleted && retraction.outputs.isEmpty)
    }

    @Test(arguments: ["duplicate", "malformed", "uppercase", "assigner", "period", "type", "role"])
    func ambiguousOrUnsupportedNativeEvidenceFailsClosed(kind: String) throws {
        var identifier: [String: Any] = ["system": NativeIdentifierFixture.system, "value": NativeIdentifierFixture.uuid]
        switch kind {
        case "malformed": identifier["value"] = "not-a-healthkit-uuid"
        case "uppercase": identifier["value"] = NativeIdentifierFixture.uuid.uppercased()
        case "assigner": identifier["assigner"] = ["reference": "Organization/foreign"]
        case "period": identifier["period"] = ["start": "2026-01-01"]
        case "type": identifier["type"] = ["text": "different meaning"]
        case "role":
            let coding = ["system": "https://grovealliance.org/fhir/mobile/CodeSystem/grove-identifier-role", "code": "source-record"]
            identifier["type"] = ["coding": [coding]]
        default: break
        }
        let bytes = try NativeIdentifierFixture.adding(kind == "duplicate" ? [identifier, identifier] : [identifier], to: fixture())
        #expect {
            try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-only")
        } throws: { ($0 as? ServerError)?.status.code == 422 }
    }

    private func fixture() throws -> Data {
        try Data(contentsOf: NativeIdentifierFixture.healthKitURL())
    }
}
