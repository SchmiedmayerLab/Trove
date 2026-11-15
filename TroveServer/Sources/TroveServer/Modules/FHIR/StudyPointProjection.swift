//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract


/// Derived FHIR views of the admitted point capability. The caller supplies exact authorized
/// outputs and a server-resolved study subject; this pure transform grants no read authority.
/// Original custody bytes, producer identities and consent history are never rewritten.
enum StudyPointProjection {
    struct EntryLineage: Sendable {
        let originalFullURL: String
        let derivedFullURL: String
        let sourceProfiles: [String]
    }

    struct Result: Sendable {
        let id: UUID
        let json: Data
        let document: StudyProjectionJSON
        let sourceRecord: BusinessIdentifier
        let sourceVersion: BusinessIdentifier
        let entries: [EntryLineage]
        /// This policy is part of the result's interpretation, not a producer conformance claim.
        let policy = "study-point-view-v1"
    }

    static func project(
        _ event: ValidatedExchangeEvent,
        outputs: Set<String>,
        subject: BusinessIdentifier,
        id: UUID = UUID(),
        recordingURLs: [String: String] = [:],
        maximumBytes: Int = StudyExportLimits.standard.bundleBytes
    ) throws -> Result {
        do {
            let record = try ExchangeRecord(validating: event.rawBytes)
            // The persisted event already passed the official validator. Recheck the local
            // receiver capability against its bytes; never trust a caller-supplied node list.
            let point = try FHIRPointProjection.project(
                validatedBytes: record.json, validatorIdentity: event.validatorIdentity, recordings: event.recordings
            )
            guard record.kind == .active, !outputs.isEmpty, Set(recordingURLs.keys).isSubset(of: outputs),
                  outputs.isSubset(of: Set(point.outputs.map(\.fullURL))) else { throw FHIRValidationClient.invalid }
            try FHIRWorkoutProjection.requireCompleteSelection(outputs, outputs: point.collectionOutputs)
            try FHIRHealthKitECGBoundary.requireCompleteSelection(outputs, outputs: point.collectionOutputs)
            let resources = try index(StudyProjectionJSON.read(record))
            let transform = StudyPointResourceProjection(resources: resources, subject: subject, outputs: outputs, recordingURLs: recordingURLs)
            let selected = try closure(outputs: outputs, provenance: record.version.fullURL, transform: transform)
            let addresses = selected.keys.sorted().map { ($0, "urn:uuid:" + UUID().uuidString.lowercased()) }
            let mapping = Dictionary(uniqueKeysWithValues: addresses)
            let entries = try addresses.map { original, derived in
                try entry(original: original, derived: derived, resources: selected, mapping: mapping)
            }
            let bundle: StudyProjectionJSON = try .object([
                "resourceType": .string("Bundle"), "id": .string(id.uuidString.lowercased()), "type": .string("collection"),
                "meta": .object(["tag": .array([StudyPointResourceProjection.subsetTag])]),
                "entry": .array(entries)
            ])
            let lineage = addresses.map { original, derived in
                EntryLineage(
                    originalFullURL: original,
                    derivedFullURL: derived,
                    sourceProfiles: resources[original]?["meta"]?["profile"]?.array?.compactMap(\.string) ?? []
                )
            }
            return try .init(
                id: id,
                json: bundle.encoded(maximumBytes: maximumBytes),
                document: bundle,
                sourceRecord: record.sourceRecord,
                sourceVersion: record.version.identifier.identifier,
                entries: lineage
            )
        } catch let error as StudyProjectionJSON.Failure {
            throw error
        } catch {
            // Decoder errors can contain retained values. A projection failure releases no partial record.
            throw ServerError.internalServerError("Study data projection is unavailable")
        }
    }

    private static func index(_ document: StudyProjectionJSON) throws -> [String: StudyProjectionJSON] {
        guard let entries = document["entry"]?.array else { throw FHIRValidationClient.invalid }
        var resources: [String: StudyProjectionJSON] = [:]
        for entry in entries {
            guard let address = entry["fullUrl"]?.string, let resource = entry["resource"],
                  resources.updateValue(resource, forKey: address) == nil else { throw FHIRValidationClient.invalid }
        }
        return resources
    }

    private static func closure(
        outputs: Set<String>, provenance: String, transform: StudyPointResourceProjection
    ) throws -> [String: StudyProjectionJSON] {
        var pending = Array(outputs) + [provenance]
        var selected: [String: StudyProjectionJSON] = [:]
        while let address = pending.popLast() {
            guard selected[address] == nil else { continue }
            let projected = try transform.resource(at: address)
            guard address == provenance || outputs.contains(address) || projected["resourceType"]?.string == "Device" else {
                throw FHIRValidationClient.invalid
            }
            selected[address] = projected
            pending.append(contentsOf: try references(in: projected))
        }
        return selected
    }

    private static func entry(
        original: String, derived: String, resources: [String: StudyProjectionJSON], mapping: [String: String]
    ) throws -> StudyProjectionJSON {
        guard let resource = resources[original], var members = try remap(resource, using: mapping).object else {
            throw FHIRValidationClient.invalid
        }
        members["id"] = try .string(String(derived.dropFirst("urn:uuid:".count)))
        // No original Grove entry key is attached to a derived representation.
        return try .object(["fullUrl": .string(derived), "resource": .object(members)])
    }
}


extension StudyPointProjection {
    private static func references(in value: StudyProjectionJSON) throws -> Set<String> {
        switch value {
        case .scalar: return []
        case .array(let elements):
            return try elements.reduce(into: Set<String>()) { $0.formUnion(try references(in: $1)) }
        case .object(let members):
            var result: Set<String> = []
            for (key, child) in members {
                if key == "reference" {
                    guard let address = child.string else { throw FHIRValidationClient.invalid }
                    result.insert(address)
                } else {
                    result.formUnion(try references(in: child))
                }
            }
            return result
        }
    }

    private static func remap(_ value: StudyProjectionJSON, using mapping: [String: String]) throws -> StudyProjectionJSON {
        switch value {
        case .scalar: return value
        case .array(let elements): return try .array(elements.map { try remap($0, using: mapping) })
        case .object(let members):
            var result: [String: StudyProjectionJSON] = [:]
            for (key, child) in members {
                if key == "reference" {
                    guard let address = child.string, let replacement = mapping[address] else { throw FHIRValidationClient.invalid }
                    result[key] = try .string(replacement)
                } else {
                    result[key] = try remap(child, using: mapping)
                }
            }
            return .object(result)
        }
    }
}
