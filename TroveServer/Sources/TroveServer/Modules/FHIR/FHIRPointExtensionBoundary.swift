//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


private enum PointExtensionLocation {
    case bundle, entries, entry, resource, targets, target, other

    var element: Self {
        switch self {
        case .entries: .entry
        case .targets: .target
        default: .other
        }
    }

    var allowsExtensions: Bool {
        switch self {
        case .entry, .resource, .target: true
        default: false
        }
    }

    func member(_ name: String) -> Self {
        switch (self, name) {
        case (.bundle, "entry"): .entries
        case (.entry, "resource"): .resource
        case (.resource, "target"): .targets
        default: .other
        }
    }
}


extension FHIRPointSupportBoundary {
    /// Runs only after complete validation. JSONSerialization is used exclusively to inspect
    /// member locations; its number representations are never projected or re-encoded.
    /// This initial receiver accepts no nested or modifier extensions. Entry identity and the
    /// supported resource-level extension meanings are checked by the IG and typed boundary.
    static func validateExtensionLocations(in bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= ValidatedQuantityLexemes.maximumBytes else { throw FHIRValidationClient.invalid }
        do {
            guard let document = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw FHIRValidationClient.invalid
            }
            try inspectExtensionLocations(document, at: .bundle, depth: 0)
        } catch {
            // Foundation errors may include input fragments. Never propagate their descriptions.
            throw FHIRValidationClient.invalid
        }
    }

    private static func inspectExtensionLocations(_ value: Any, at location: PointExtensionLocation, depth: Int) throws {
        if let object = value as? [String: Any] {
            guard depth < ValidatedQuantityLexemes.maximumDepth else { throw FHIRValidationClient.invalid }
            for (key, child) in object {
                guard key != "modifierExtension" else { throw FHIRValidationClient.invalid }
                if key == "extension" {
                    guard location.allowsExtensions, child is [Any] else { throw FHIRValidationClient.invalid }
                }
                try inspectExtensionLocations(child, at: location.member(key), depth: depth + 1)
            }
        } else if let array = value as? [Any] {
            guard depth < ValidatedQuantityLexemes.maximumDepth else { throw FHIRValidationClient.invalid }
            for child in array {
                try inspectExtensionLocations(child, at: location.element, depth: depth + 1)
            }
        }
    }
}
