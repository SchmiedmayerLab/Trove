//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import Testing
import TroveAPITypes


struct PseudonymousIdentifierSystemsTests {
    private static let systems = Components.Schemas.PseudonymousIdentifierSystems(
        sourceRecord: "https://example.test/source-record",
        sourceOutput: "https://example.test/source-output",
        writerRecord: "https://example.test/writer-record",
        providerRecord: "https://example.test/provider-record",
        providerOutput: "https://example.test/provider-output",
        sourceArtifact: "https://example.test/source-artifact",
        providerArtifact: "https://example.test/provider-artifact",
        sourceContext: "https://example.test/source-context",
        recordingDevice: "https://example.test/recording-device",
        deviceSnapshot: "https://example.test/device-snapshot"
    )

    @Test
    func roundTripPreservesTheCompleteTypedSet() throws {
        let bytes = try JSONEncoder().encode(Self.systems)
        let decoded = try JSONDecoder().decode(Components.Schemas.PseudonymousIdentifierSystems.self, from: bytes)
        let typed = try decoded.groveSystems()
        #expect(Components.Schemas.PseudonymousIdentifierSystems(typed) == Self.systems)
        #expect(typed.all.count == PseudonymousIdentityKind.allCases.count)
        #expect(Set(typed.all).count == 10)
    }

    @Test
    func duplicateNamespacesCannotBecomeAConversionContext() {
        var received = Self.systems
        received.sourceOutput = received.sourceRecord
        #expect(throws: PseudonymousIdentityError.reusedIdentifierSystem) { try received.groveSystems() }
    }

    @Test(arguments: ["", "/relative", "not a URI", "https://example.test/" + String(repeating: "a", count: 512)])
    func invalidNamespaceCannotBecomeAConversionContext(value: String) {
        var received = Self.systems
        received.recordingDevice = value
        #expect(throws: ExchangeIdentityError.self) { try received.groveSystems() }
    }

    @Test(arguments: [
        "sourceRecord", "sourceOutput", "writerRecord", "providerRecord", "providerOutput",
        "sourceArtifact", "providerArtifact", "sourceContext", "recordingDevice", "deviceSnapshot"
    ])
    func incompleteResponseDoesNotSupplyDefaults(missing: String) throws {
        let bytes = try JSONEncoder().encode(Self.systems)
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: String])
        object.removeValue(forKey: missing)
        let incomplete = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Components.Schemas.PseudonymousIdentifierSystems.self, from: incomplete)
        }
    }
}
