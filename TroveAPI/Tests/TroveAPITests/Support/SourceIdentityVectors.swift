//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Shared participant source identity vectors. TroveServer tests decode the same checked-in file.
struct SourceIdentityVectors: Decodable {
    struct Identifier: Decodable, Equatable {
        let system: String
        let value: String
    }

    struct Context: Decodable {
        let identifierRoot: String
        let keyID: String
        let keyEpoch: String
        let keyHex: String
        let repositoryKind: String
        let repositoryScope: Identifier
        let participantIdentifier: Identifier

        var key: Data {
            Data(stride(from: 0, to: keyHex.count, by: 2).compactMap { offset in
                let start = keyHex.index(keyHex.startIndex, offsetBy: offset)
                return UInt8(keyHex[start..<keyHex.index(start, offsetBy: 2)], radix: 16)
            })
        }

        /// The source ID is the final path component of the server-assigned root.
        var sourceID: String {
            String(identifierRoot.split(separator: "/").last ?? "")
        }
    }

    struct Output: Decodable {
        let role: String
        let discriminator: String
        let identifier: Identifier
    }

    struct SourceRecord: Decodable {
        let adapterID: String
        let sourceType: String
        let repositoryScope: Identifier
        let nativeRecordID: String
        let sourceRecord: Identifier
        let outputs: [Output]
    }

    struct ProviderRecord: Decodable {
        let provider: String
        let sourceType: String
        let providerScope: Identifier
        let scope: String
        let nativeRecordID: String
        let providerRecord: Identifier
    }

    static let fileName = "source-identity-vectors"

    let context: Context
    let systems: [String: String]
    let nativeRecordIdentifierSystem: String
    let sourceRecords: [SourceRecord]
    let providerRecords: [ProviderRecord]

    static func load(from url: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
