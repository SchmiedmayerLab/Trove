//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveFHIRContract


extension Components.Schemas.PseudonymousIdentifierSystems {
    /// Encodes Grove's complete namespace set without changing its identity strings.
    public init(_ systems: PseudonymousIdentitySystems) {
        self.init(
            sourceRecord: systems.sourceRecord.rawValue,
            sourceOutput: systems.sourceOutput.rawValue,
            writerRecord: systems.writerRecord.rawValue,
            providerRecord: systems.providerRecord.rawValue,
            providerOutput: systems.providerOutput.rawValue,
            sourceArtifact: systems.sourceArtifact.rawValue,
            providerArtifact: systems.providerArtifact.rawValue,
            sourceContext: systems.sourceContext.rawValue,
            recordingDevice: systems.recordingDevice.rawValue,
            deviceSnapshot: systems.deviceSnapshot.rawValue
        )
    }

    /// Validates URI syntax and kind separation before using a received namespace set.
    public func groveSystems() throws -> PseudonymousIdentitySystems {
        func system(_ value: String) throws -> IdentifierSystem {
            guard value.utf8.count <= 512 else { throw ExchangeIdentityError.invalidIdentifierSystem(value) }
            return try IdentifierSystem(value)
        }
        return try .init(
            sourceRecord: system(sourceRecord),
            sourceOutput: system(sourceOutput),
            writerRecord: system(writerRecord),
            providerRecord: system(providerRecord),
            providerOutput: system(providerOutput),
            sourceArtifact: system(sourceArtifact),
            providerArtifact: system(providerArtifact),
            sourceContext: system(sourceContext),
            recordingDevice: system(recordingDevice),
            deviceSnapshot: system(deviceSnapshot)
        )
    }
}
