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
import Testing


/// Synthetic shape-valid keys for local storage/boundary tests, not producer conformance.
/// Full-validator fixtures derive content keys with the independently pinned IG implementation.
enum FixtureIdentity {
    static func opaque(system: IdentifierSystem, role: GroveIdentifierRole, components: [String]) throws -> RoledIdentifier {
        let key = SymmetricKey(data: Data(repeating: 0xA5, count: 32))
        let fields = ["org.grovealliance.fhir.identity.v0", role.rawValue] + components
        let digest = encoded(Data(HMAC<SHA256>.authenticationCode(for: try frame(fields), using: key)))
        return .init(identifier: try BusinessIdentifier(system: system, value: "v0:local-test:1:\(digest)"), role: role)
    }

    private static func frame(_ fields: [String]) throws -> Data {
        var result = Data()
        for field in fields {
            var length = try #require(UInt32(exactly: field.utf8.count)).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(contentsOf: field.utf8)
        }
        return result
    }

    private static func encoded(_ bytes: Data) -> String {
        bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
