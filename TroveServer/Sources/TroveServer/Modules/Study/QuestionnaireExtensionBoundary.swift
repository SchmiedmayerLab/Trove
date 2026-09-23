//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Checks extension locations, including primitive metadata that a renderer could ignore.
/// Typed FHIR decoding follows; this traversal neither interprets values nor rewrites bytes.
struct QuestionnaireExtensionBoundary: Decodable {
    private struct Member: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            self.init(stringValue: String(intValue))
        }
    }

    init(from decoder: any Decoder) throws {
        guard decoder.codingPath.count <= 64 else { throw QuestionnaireValidationService.unsupported }
        if let container = try? decoder.container(keyedBy: Member.self) {
            for member in container.allKeys {
                guard member.stringValue != "modifierExtension",
                      member.stringValue != "extension" || decoder.codingPath.isEmpty else {
                    throw QuestionnaireValidationService.unsupported
                }
                _ = try container.decode(Self.self, forKey: member)
            }
        } else if var container = try? decoder.unkeyedContainer() {
            while !container.isAtEnd {
                _ = try container.decode(Self.self)
            }
        }
    }
}
