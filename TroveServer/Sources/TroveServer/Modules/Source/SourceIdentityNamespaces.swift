//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract


enum SourceIdentityNamespaces {
    /// Namespace assignment is public metadata, never evidence of source ownership.
    static func assign(root: String, registrationID: UUID) throws -> DeploymentIdentifierSystems {
        try .derived(
            root: IdentifierSystem(root), keyID: registrationID.uuidString.lowercased(), epoch: EventSequence(1)
        )
    }
}
