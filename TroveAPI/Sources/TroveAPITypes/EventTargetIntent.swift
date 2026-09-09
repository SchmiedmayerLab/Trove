//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation


/// Canonical exact-consent/output intent shared by receipt producers and consumers.
public struct EventTargetIntent: Sendable {
    public struct Target: Codable, Sendable, Equatable {
        enum CodingKeys: String, CodingKey {
            case consentID = "consentId"
            case outputFullURLs = "outputFullUrls"
        }

        public let consentID: UUID
        public let outputFullURLs: [String]

        public init(consentID: UUID, outputFullURLs: [String]) {
            self.consentID = consentID
            self.outputFullURLs = outputFullURLs
        }

        public func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(consentID.uuidString.lowercased(), forKey: .consentID)
            try values.encode(outputFullURLs, forKey: .outputFullURLs)
        }
    }

    public enum ValidationError: Error, Equatable {
        case invalidTargets
        case oversizedIntent
    }

    public static let maximumBytes = 512 * 1024
    public let targets: [Target]
    public let serialized: String

    public var sha256: String {
        SHA256.hash(data: Data(serialized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public init(targets: [Target]) throws {
        // Empty intent is used by restrictive lifecycle events, never active collection.
        // Admission, not receipt canonicalization, establishes the event's authority.
        guard targets.count <= 16, Set(targets.map(\.consentID)).count == targets.count,
              targets.allSatisfy({ target in
                  (1...512).contains(target.outputFullURLs.count)
                      && Set(target.outputFullURLs).count == target.outputFullURLs.count
                      && target.outputFullURLs.allSatisfy { url in
                          (1...512).contains(url.utf8.count) && url.utf8.allSatisfy { (33...126).contains($0) }
                      }
              }) else { throw ValidationError.invalidTargets }
        self.targets = targets.map { .init(consentID: $0.consentID, outputFullURLs: $0.outputFullURLs.sorted()) }
            .sorted { $0.consentID.uuidString < $1.consentID.uuidString }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(self.targets)
        guard bytes.count <= Self.maximumBytes else { throw ValidationError.oversizedIntent }
        serialized = String(decoding: bytes, as: UTF8.self)
    }
}
