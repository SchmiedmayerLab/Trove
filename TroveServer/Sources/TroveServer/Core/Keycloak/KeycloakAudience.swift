//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

/// JWTKit's AudienceClaim initializer preconditions on an empty array. Untrusted
/// claims must fail decoding instead of terminating the server process.
struct KeycloakAudience: Codable, Sendable {
    var value: [String]

    init(value: [String]) {
        self.value = value
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let values = try? container.decode([String].self) {
            guard !values.isEmpty else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Audience must not be empty")
            }
            self.value = values
        } else {
            self.value = [try container.decode(String.self)]
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if value.count == 1, let audience = value.first {
            try container.encode(audience)
        } else {
            try container.encode(value)
        }
    }
}
