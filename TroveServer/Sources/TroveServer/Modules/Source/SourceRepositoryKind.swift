//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveFHIRContract


/// Distinct native repositories never merge records by matching values or timestamps.
/// An identity assignment does not imply that the receiver admits every adapter output.
enum SourceRepositoryKind: String, Codable, Sendable {
    case healthKit = "healthkit"
    case sensorKit = "sensorkit"
}


extension SourceBinding {
    var repositoryScope: BusinessIdentifier {
        get throws {
            try BusinessIdentifier(system: IdentifierSystem(identifierRoot + "/repository"), value: repositoryKind.rawValue)
        }
    }

    var keyContext: SourceIdentityKeyContext {
        get throws {
            try .init(
                owner: (participantID, id), keyID: keyID, epoch: keyEpoch, identifierRoot: identifierRoot, repository: repositoryScope
            )
        }
    }
}
