//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract


private enum PointExtensionLocation {
    case bundle, entries, entry, resource, resourceExtensions, resourceExtension, targets, target, entities, entity
    case components, component, componentExtensions, componentExtension
    case documentContext, period, temporalPrimitive, codedValue, other

    var element: Self {
        switch self {
        case .entries: .entry
        case .targets: .target
        case .entities: .entity
        case .resourceExtensions: .resourceExtension
        case .components: .component
        case .componentExtensions: .componentExtension
        default: .other
        }
    }

    var allowsExtensions: Bool {
        switch self {
        case .entry, .resource, .target, .entity, .temporalPrimitive, .codedValue, .component: true
        default: false
        }
    }

    private static func resourceMember(_ name: String) -> Self {
        switch name {
        case "extension": .resourceExtensions
        case "target": .targets
        case "entity": .entities
        case "valueCodeableConcept": .codedValue
        case "context": .documentContext
        case "component": .components
        case "effectivePeriod", "occurredPeriod": .period
        case "_effectiveDateTime", "_issued", "_authored", "_occurredDateTime": .temporalPrimitive
        default: .other
        }
    }

    func member(_ name: String) -> Self {
        switch (self, name) {
        case (.bundle, "entry"): .entries
        case (.entry, "resource"): .resource
        case (.resource, _): Self.resourceMember(name)
        case (.documentContext, "period"): .period
        case (.component, "extension"): .componentExtensions
        case (.component, "valuePeriod"): .period
        case (.period, "_start"), (.period, "_end"): .temporalPrimitive
        default: .other
        }
    }
}


extension FHIRPointSupportBoundary {
    /// Runs only after complete validation. JSONSerialization is used exclusively to inspect
    /// member locations; its number representations are never projected or re-encoded.
    /// Temporal primitives may retain the standard timezone code. Other nested extensions and
    /// modifier extensions remain outside this receiver capability. Entry identity and supported
    /// resource-level extension meanings are checked by the IG and typed boundary.
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

    private static func isRetainedMetadata(_ object: [String: Any], at location: PointExtensionLocation) -> Bool {
        location == .resourceExtension && object["url"] as? String == FHIRHealthKitMetadataBoundary.url
    }

    private static func inspectExtensionLocations(_ value: Any, at location: PointExtensionLocation, depth: Int) throws {
        if let object = value as? [String: Any] {
            guard depth < ValidatedQuantityLexemes.maximumDepth else { throw FHIRValidationClient.invalid }
            if location == .componentExtension {
                try FHIRHealthKitAudiogramBoundary.validateLocations(object)
                return
            }
            if isRetainedMetadata(object, at: location) {
                try FHIRHealthKitMetadataBoundary.validateLocations(object)
                return
            }
            try inspectObjectMembers(object, at: location, depth: depth)
        } else if let array = value as? [Any] {
            guard depth < ValidatedQuantityLexemes.maximumDepth else { throw FHIRValidationClient.invalid }
            for child in array {
                try inspectExtensionLocations(child, at: location.element, depth: depth + 1)
            }
        }
    }

    private static func inspectObjectMembers(_ object: [String: Any], at location: PointExtensionLocation, depth: Int) throws {
        for (key, child) in object {
            guard key != "modifierExtension" else { throw FHIRValidationClient.invalid }
            if key == "extension" {
                guard location.allowsExtensions, child is [Any] else { throw FHIRValidationClient.invalid }
                if location == .entity {
                    try sourceEntityExtensions(child)
                    continue
                }
                try validateNestedExtensions(child, at: location)
            }
            try inspectExtensionLocations(child, at: location.member(key), depth: depth + 1)
        }
    }

    private static func validateNestedExtensions(_ value: Any, at location: PointExtensionLocation) throws {
        switch location {
        case .temporalPrimitive: try timezoneExtensions(value)
        case .codedValue: try unmappedSourceValues(value)
        default: break
        }
    }

    private static func sourceEntityExtensions(_ value: Any) throws {
        guard let extensions = value as? [[String: Any]], extensions.count <= 2 else { throw FHIRValidationClient.invalid }
        var seen: Set<String> = []
        for item in extensions {
            guard let url = item["url"] as? String, seen.insert(url).inserted else { throw FHIRValidationClient.invalid }
            if url == HealthKitSourceDocumentTime.extensionURL.value?.url.absoluteString {
                try sourceDocumentTime(item)
            } else {
                try sourceRevision([item])
            }
        }
    }

    private static func sourceDocumentTime(_ item: [String: Any]) throws {
        guard Set(item.keys) == ["url", "extension"], let children = item["extension"] as? [[String: Any]], children.count == 2,
              let basis = children.first(where: { $0["url"] as? String == "basis" }), Set(basis.keys) == ["url", "valueCode"],
              let code = basis["valueCode"] as? String, HealthKitSourceDocumentTime.Basis(rawValue: code) != nil,
              let period = children.first(where: { $0["url"] as? String == "period" }), Set(period.keys) == ["url", "valuePeriod"],
              let bounds = period["valuePeriod"] as? [String: Any], bounds["start"] is String, bounds["end"] is String else {
            throw FHIRValidationClient.invalid
        }
        try inspectExtensionLocations(bounds, at: .period, depth: 0)
    }

    private static func sourceRevision(_ value: Any) throws {
        guard let extensions = value as? [[String: Any]], extensions.count <= 1 else { throw FHIRValidationClient.invalid }
        let allowed: Set<String> = ["sourceName", "sourceBundleIdentifier", "version", "productType", "operatingSystemVersion"]
        for item in extensions {
            guard Set(item.keys) == ["url", "extension"],
                  item["url"] as? String == "https://grovealliance.org/fhir/healthkit/StructureDefinition/healthkit-source-revision",
                  let facts = item["extension"] as? [[String: Any]], !facts.isEmpty, facts.count <= allowed.count else {
                throw FHIRValidationClient.invalid
            }
            var keys: Set<String> = []
            for fact in facts {
                guard Set(fact.keys) == ["url", "valueString"], let key = fact["url"] as? String,
                      allowed.contains(key), keys.insert(key).inserted,
                      let text = fact["valueString"] as? String, !text.isEmpty else { throw FHIRValidationClient.invalid }
            }
        }
    }

    private static func timezoneExtensions(_ value: Any) throws {
        guard let extensions = value as? [[String: Any]], extensions.count <= 1 else { throw FHIRValidationClient.invalid }
        for item in extensions {
            guard Set(item.keys) == ["url", "valueCode"],
                  item["url"] as? String == "http://hl7.org/fhir/StructureDefinition/timezone",
                  let code = item["valueCode"] as? String, !code.isEmpty else { throw FHIRValidationClient.invalid }
        }
    }

    private static func unmappedSourceValues(_ value: Any) throws {
        guard let extensions = value as? [[String: Any]], extensions.count <= 1 else { throw FHIRValidationClient.invalid }
        for item in extensions {
            guard Set(item.keys) == ["url", "valueString"],
                  item["url"] as? String == "https://grovealliance.org/fhir/healthkit/StructureDefinition/healthkit-unmapped-source-value",
                  let raw = item["valueString"] as? String, !raw.isEmpty else { throw FHIRValidationClient.invalid }
        }
    }
}
