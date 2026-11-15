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


struct ProviderIdentityNamespaceTests {
    @Test(arguments: [GroveIdentifierRole.sourceRecord, .sourceOutput, .sourceArtifact])
    func providerNamespacesCannotMasqueradeAsNativeOrCrossARegisteredRoot(role: GroveIdentifierRole) throws {
        let expected = try SourceIdentityNamespaces.assign(root: "https://example.test/sources/one", keyID: UUID())
        let providerSystem = FHIRDeploymentIdentifiers.system(for: role, in: expected, provider: true).rawValue
        var evidence = FHIRDeploymentIdentifiers(systems: [.recordVersion: [expected.recordVersion.rawValue], role: [providerSystem]])
        #expect(evidence.matches(expected, provider: true))
        #expect(!evidence.matches(expected))
        evidence.systems[role] = [FHIRDeploymentIdentifiers.system(for: role, in: expected).rawValue]
        #expect(evidence.matches(expected))
        #expect(!evidence.matches(expected, provider: true))
        evidence.systems[role] = ["https://foreign.example/provider-identity"]
        #expect(!evidence.matches(expected, provider: true))
    }
}
