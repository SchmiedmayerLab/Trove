//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import GroveFHIRContract


/// Immutable, server-assigned ownership and identity metadata authenticated with every encrypted key.
struct SourceIdentityKeyContext: Sendable {
    let participantID: UUID
    let sourceID: UUID
    let keyID: UUID
    let epoch: KeyEpoch
    let identifierRoot: String
    let repository: BusinessIdentifier

    init(
        owner: (participantID: UUID, sourceID: UUID), keyID: UUID, epoch: KeyEpoch, identifierRoot: String, repository: BusinessIdentifier
    ) throws {
        guard (1...256).contains(identifierRoot.utf8.count), epoch.rawValue.utf8.count <= 32,
              repository.system.rawValue.utf8.count <= 512, repository.value.utf8.count <= 256 else {
            throw SourceIdentityKeyring.Failure.invalidContext
        }
        do {
            _ = try DeploymentIdentifierSystems.derived(root: IdentifierSystem(identifierRoot), keyID: keyID.uuidString.lowercased(), epoch: epoch)
        } catch {
            throw SourceIdentityKeyring.Failure.invalidContext
        }
        self.participantID = owner.participantID
        self.sourceID = owner.sourceID
        self.keyID = keyID
        self.epoch = epoch
        self.identifierRoot = identifierRoot
        self.repository = repository
    }

    /// Envelope v1: fixed-order UTF-8 fields, each prefixed by its unsigned 32-bit big-endian byte length.
    /// Explicit framing preserves exact identifier bytes and avoids separator and Unicode-normalization ambiguities.
    func authenticatedData(encryptionKeyID: String) -> Data {
        let fields = [
            "trove.source-identity-key.v1", encryptionKeyID,
            participantID.uuidString.lowercased(), sourceID.uuidString.lowercased(), keyID.uuidString.lowercased(),
            epoch.rawValue, identifierRoot, repository.system.rawValue, repository.value
        ]
        var data = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            var length = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return data
    }
}
