// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import GroveFHIRContract
import ModelsR4


/// Retains the guide's typed source facts without treating them as clinical values or references.
/// Full validation establishes datatype constraints; this boundary excludes unhandled nested graph edges.
enum FHIRHealthKitMetadataBoundary {
    static var url: String { Canonicals.healthKitSourceMetadata.value?.url.absoluteString ?? "" }

    static func accepts(_ value: Extension, resourceType: String) throws -> Bool {
        guard value.url.value?.url.absoluteString == url else {
            return false
        }
        guard ["Observation", "DocumentReference"].contains(resourceType), value.value == nil,
              let entries = value.extension, !entries.isEmpty else { throw FHIRValidationClient.invalid }
        var keys: Set<[UInt8]> = []
        for entry in entries {
            guard entry.url.value?.url.absoluteString == "entry", entry.value == nil,
                  let fields = entry.extension, fields.count == 2,
                  let key = fields.first(where: { $0.url.value?.url.absoluteString == "key" }),
                  let field = fields.first(where: { $0.url.value?.url.absoluteString == "value" }),
                  key.extension?.isEmpty != false, field.extension?.isEmpty != false,
                  case .string(let primitive)? = key.value, let text = primitive.value?.string,
                  !text.isEmpty, keys.insert(Array(text.utf8)).inserted else { throw FHIRValidationClient.invalid }
            switch field.value {
            case .string, .boolean, .decimal, .dateTime: break
            case .coding(let coding):
                guard coding.extension?.isEmpty != false else { throw FHIRValidationClient.invalid }
            case .quantity(let quantity):
                guard quantity.extension?.isEmpty != false else { throw FHIRValidationClient.invalid }
            default: throw FHIRValidationClient.invalid
            }
        }
        return true
    }

    /// Member-location walk only; never rewrites numeric tokens or overrides the typed FHIR projection.
    static func validateLocations(_ object: [String: Any]) throws {
        guard Set(object.keys) == ["url", "extension"],
              let entries = object["extension"] as? [[String: Any]], !entries.isEmpty else { throw FHIRValidationClient.invalid }
        let primitiveValues: Set<String> = ["valueString", "valueBoolean", "valueDecimal", "valueDateTime"]
        for entry in entries {
            guard Set(entry.keys) == ["url", "extension"], entry["url"] as? String == "entry",
                  let fields = entry["extension"] as? [[String: Any]], fields.count == 2 else { throw FHIRValidationClient.invalid }
            for field in fields {
                guard let name = field["url"] as? String, ["key", "value"].contains(name), field.count == 2 else {
                    throw FHIRValidationClient.invalid
                }
                let values = Set(field.keys).subtracting(["url"])
                if name == "key" {
                    guard values == ["valueString"] else { throw FHIRValidationClient.invalid }
                } else if let member = values.first, ["valueCoding", "valueQuantity"].contains(member) {
                    guard let scalar = field[member] as? [String: Any],
                          scalar.values.allSatisfy({ !($0 is [String: Any]) && !($0 is [Any]) }),
                          scalar["extension"] == nil, scalar["modifierExtension"] == nil else { throw FHIRValidationClient.invalid }
                } else {
                    guard values.isSubset(of: primitiveValues), values.count == 1 else { throw FHIRValidationClient.invalid }
                }
            }
        }
    }
}
