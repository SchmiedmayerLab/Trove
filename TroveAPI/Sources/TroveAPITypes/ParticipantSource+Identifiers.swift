//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract


extension Components.Schemas.ParticipantSource {
    /// Derives Grove's complete namespace set from the immutable server assignment.
    /// Installations recover this context without changing the participant source identity.
    public func identifierSystems() throws -> DeploymentIdentifierSystems {
        guard (1...256).contains(identifierRoot.utf8.count),
              let key = UUID(uuidString: keyID), keyID == key.uuidString.lowercased(),
              repositoryScope.system == identifierRoot + "/repository",
              repositoryScope.value == repositoryKind.rawValue else {
            throw ExchangeIdentityError.invalidIdentifierSystem(identifierRoot)
        }
        let systems = try DeploymentIdentifierSystems.derived(
            root: IdentifierSystem(identifierRoot), keyID: keyID, epoch: KeyEpoch(keyEpoch)
        )
        guard systems.recordVersion.rawValue.utf8.elementsEqual(eventIdentifierSystem.utf8) else {
            throw ExchangeIdentityError.invalidIdentifierSystem(eventIdentifierSystem)
        }
        return systems
    }
}


extension Components.Schemas.ParticipantSourceRegistration {
    /// Either revocation permanently disables this installation.
    public var isRevoked: Bool { source.revokedAt != nil || installation.revokedAt != nil }
}
