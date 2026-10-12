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
    /// One registration owns one key epoch; losing its key requires a new registration.
    public func identifierSystems() throws -> DeploymentIdentifierSystems {
        guard (1...256).contains(identifierRoot.utf8.count),
              let registration = UUID(uuidString: registrationID),
              registrationID == registration.uuidString.lowercased() else {
            throw ExchangeIdentityError.invalidIdentifierSystem(identifierRoot)
        }
        let systems = try DeploymentIdentifierSystems.derived(
            root: IdentifierSystem(identifierRoot), keyID: registrationID, epoch: EventSequence(1)
        )
        guard systems.event.rawValue.utf8.elementsEqual(eventIdentifierSystem.utf8) else {
            throw ExchangeIdentityError.invalidIdentifierSystem(eventIdentifierSystem)
        }
        return systems
    }
}
