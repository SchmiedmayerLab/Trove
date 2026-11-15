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


struct ParticipantSourceIdentifierTests {
    @Test
    func nativeNamespaceIsStoreScopedAndIndependentOfKeyEpoch() throws {
        let original = DeliveryFixture.binding(sourceID: UUID(), registrationID: UUID()).source
        var rotated = original
        rotated.keyID = UUID().uuidString.lowercased()
        rotated.keyEpoch = "2"
        let systems = try DeploymentIdentifierSystems.derived(
            root: IdentifierSystem(rotated.identifierRoot), keyID: rotated.keyID, epoch: KeyEpoch(rotated.keyEpoch)
        )
        rotated.eventIdentifierSystem = systems.recordVersion.rawValue
        let native = try original.nativeRecordIdentifierSystem()
        #expect(native == (try rotated.nativeRecordIdentifierSystem()))
        #expect(native.rawValue == original.identifierRoot + "/NamingSystem/healthkit-native-record")
        #expect(native != systems.sourceRecord && native != systems.sourceOutput && native != systems.recordVersion)
    }

    @Test
    func roundTripDerivesAllThirteenDistinctSystems() throws {
        let source = DeliveryFixture.binding(sourceID: UUID(), registrationID: UUID()).source
        let decoded = try JSONDecoder().decode(Components.Schemas.ParticipantSource.self, from: JSONEncoder().encode(source))
        let systems = try decoded.identifierSystems()
        #expect(systems == (try source.identifierSystems()))
        #expect(systems.recordVersion.rawValue == source.eventIdentifierSystem)
        #expect(Set([
            systems.sourceRecord, systems.sourceOutput, systems.writerRecord, systems.providerRecord, systems.providerOutput,
            systems.sourceArtifact, systems.providerArtifact, systems.sourceContext, systems.recordingDevice,
            systems.deviceSnapshot, systems.contextSnapshot, systems.recordVersion, systems.recordRetraction
        ]).count == 13)
    }

    @Test(arguments: ["", "/relative", "not a URI", "https://example.test/" + String(repeating: "a", count: 256)])
    func invalidRootCannotBecomeAConversionContext(root: String) {
        var source = DeliveryFixture.binding(sourceID: UUID(), registrationID: UUID()).source
        source.identifierRoot = root
        #expect(throws: ExchangeIdentityError.self) { try source.identifierSystems() }
    }

    @Test
    func inconsistentEventNamespaceIsRejected() {
        var source = DeliveryFixture.binding(sourceID: UUID(), registrationID: UUID()).source
        source.eventIdentifierSystem = "https://foreign.test/events"
        #expect(throws: ExchangeIdentityError.self) { try source.identifierSystems() }
    }

    @Test(arguments: ["identifierRoot", "keyID", "keyEpoch", "repositoryScope", "repositoryKind", "eventIdentifierSystem"])
    func incompleteResponseDoesNotSupplyDefaults(missing: String) throws {
        let source = DeliveryFixture.binding(sourceID: UUID(), registrationID: UUID()).source
        let bytes = try JSONEncoder().encode(source)
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object.removeValue(forKey: missing)
        let incomplete = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Components.Schemas.ParticipantSource.self, from: incomplete)
        }
    }
}
