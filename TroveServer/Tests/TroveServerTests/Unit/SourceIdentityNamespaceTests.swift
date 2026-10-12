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
@testable import TroveServer


struct SourceIdentityNamespaceTests {
    @Test
    func namespaceAssignmentIsPinnedIndependentlyOfTheImplementation() throws {
        let root = "https://trove.test/sources/11111111-2222-4333-8444-555555555555"
        let nonce = try #require(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
        let systems = try SourceIdentityNamespaces.assign(root: root, registrationID: nonce)
        // Pin the published path forms independently of Grove's derivation helper.
        let opaque: [(IdentifierSystem, String)] = [
            (systems.sourceRecord, "source-record"), (systems.sourceOutput, "source-output"),
            (systems.writerRecord, "writer-record"), (systems.providerRecord, "provider-record"),
            (systems.providerOutput, "provider-output"), (systems.sourceArtifact, "source-artifact"),
            (systems.providerArtifact, "provider-artifact"), (systems.sourceContext, "source-context"),
            (systems.recordingDevice, "recording-device"), (systems.deviceSnapshot, "device-snapshot")
        ]
        for (system, kind) in opaque {
            #expect(system.rawValue == root + "/NamingSystem/grove-\(kind)-v0/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee/1")
        }
        #expect(systems.event.rawValue == root + "/NamingSystem/grove-event-v0")
        #expect(systems.entryNode.rawValue == root + "/NamingSystem/grove-entry-node-v0")
        #expect(Set(opaque.map(\.0) + [systems.event, systems.entryNode]).count == 12)
    }
}
