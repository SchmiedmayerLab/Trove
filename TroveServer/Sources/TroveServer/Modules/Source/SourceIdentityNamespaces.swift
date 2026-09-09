//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveFHIRContract


enum SourceIdentityNamespaces {
    /// Public namespace assignment only, never key generation or native-record pseudonymization.
    /// The versioned names and Grove UUIDv5 mapping are pinned by fixed-vector tests.
    static func assign(eventSystem: String) throws -> PseudonymousIdentitySystems {
        func system(_ kind: PseudonymousIdentityKind) throws -> IdentifierSystem {
            let identifier = try BusinessIdentifier(
                system: eventSystem,
                value: "trove-source-namespace-v1:\(kind.rawValue)"
            )
            return try IdentifierSystem(ExchangeIdentity.fullURL(for: identifier))
        }
        return try .init(
            sourceRecord: system(.sourceRecord),
            sourceOutput: system(.sourceOutput),
            writerRecord: system(.writerRecord),
            providerRecord: system(.providerRecord),
            providerOutput: system(.providerOutput),
            sourceArtifact: system(.sourceArtifact),
            providerArtifact: system(.providerArtifact),
            sourceContext: system(.sourceContext),
            recordingDevice: system(.recordingDevice),
            deviceSnapshot: system(.deviceSnapshot)
        )
    }
}
