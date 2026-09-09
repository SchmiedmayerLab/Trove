//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveFHIRContract
import Testing
@testable import TroveServer


struct SourceIdentityNamespaceTests {
    @Test
    func namespaceAssignmentIsPinnedIndependentlyOfTheImplementation() throws {
        // Independently calculated with Python hashlib/uuid, unsigned big-endian length framing,
        // and Grove's published UUID namespace. Never regenerate these from the Swift helper.
        let expected: [PseudonymousIdentityKind: String] = [
            .sourceRecord: "urn:uuid:b8221227-fc3d-5658-a52a-51ac041a7ea3",
            .sourceOutput: "urn:uuid:70010e2f-875f-5fd0-9c77-ae3002a56eea",
            .writerRecord: "urn:uuid:42eb1751-8156-553b-b244-eb2e7ba9f219",
            .providerRecord: "urn:uuid:4c60852d-90a6-5348-bffd-d14192c49362",
            .providerOutput: "urn:uuid:4f2b3f7c-b6aa-5b48-bd9e-f97d6e25bad4",
            .sourceArtifact: "urn:uuid:1a3e2f71-aaa4-5b36-9002-93cdd3e5ac06",
            .providerArtifact: "urn:uuid:83272e99-cadd-593d-a1fd-455153e25b69",
            .sourceContext: "urn:uuid:ef0989c9-0531-5c22-acfd-47279c368ae3",
            .recordingDevice: "urn:uuid:d3d80881-a3f5-5e48-96b8-1c09db32e0be",
            .deviceSnapshot: "urn:uuid:40902187-a72f-5c4f-ae81-aff56f182216"
        ]
        let systems = try SourceIdentityNamespaces.assign(eventSystem: "urn:uuid:11111111-2222-4333-8444-555555555555")
        #expect(Set(expected.keys) == Set(PseudonymousIdentityKind.allCases))
        for kind in PseudonymousIdentityKind.allCases {
            #expect(systems[kind].rawValue == expected[kind])
        }
    }
}
