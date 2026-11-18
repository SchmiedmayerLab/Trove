//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract


/// Assembles receiver-owned historical study context and derivation Provenance around a
/// filtered point graph. Inputs must come from the authorized, transaction-fenced grant read.
/// Neither this builder nor a study/grant identifier supplied to it establishes access.
enum StudyPointExport {
    struct Grant: Sendable {
        let id: UUID
        let outputFullURL: String
        let enrollment: StudyEnrollment
    }

    struct Context: Sendable {
        let subject: BusinessIdentifier
        let exportSystem: IdentifierSystem
        let grantSystem: IdentifierSystem
        let receiver: BusinessIdentifier
        let recordedAt: Date
        var enrollmentEndsAt: Date?
    }

    struct Result: Sendable {
        let id: UUID
        let json: Data
        let policy: String
        /// Internal mapping for the disclosure service; do not expose raw custody addresses as an access route.
        let sourceEntries: [StudyPointProjection.EntryLineage]
    }

    static let maximumEntries = 4096

    static func build(
        _ event: ValidatedExchangeEvent,
        grants: [Grant],
        context: Context,
        receivesDeviceUnitIdentifiers: Bool,
        id: UUID = UUID(),
        recordingURLs: [String: String] = [:],
        maximumBytes: Int = StudyExportLimits.standard.bundleBytes
    ) throws -> Result {
        do {
            try validate(grants, context: context)
            let point = try StudyPointProjection.project(
                event,
                outputs: Set(grants.map(\.outputFullURL)),
                subject: context.subject,
                receivesDeviceUnitIdentifiers: receivesDeviceUnitIdentifiers,
                id: id,
                recordingURLs: recordingURLs,
                maximumBytes: maximumBytes
            )
            let snapshots = try StudyExportContextSnapshots.build(grants: grants, context: context)
            let entries = try associating(point, grants: grants, studies: snapshots.studies) + snapshots.entries
            guard entries.count < maximumEntries else { throw StudyProjectionJSON.Failure.outputTooLarge }
            guard var bundle = point.document.object else { throw FHIRValidationClient.invalid }
            let policies = ["urn:trove:" + point.policy] + (receivesDeviceUnitIdentifiers ? [] : [StudyDeviceUnitDisclosure.withheldPolicy])
            let provenance = try derivation(entries: entries, grants: grants, context: context, policies: policies)
            bundle["entry"] = .array(entries + [provenance])
            bundle["identifier"] = try identifier(system: context.exportSystem.rawValue, value: id.uuidString.lowercased())
            bundle["timestamp"] = try .string(timestamp(context.recordedAt))
            return try .init(
                id: id,
                json: StudyProjectionJSON.object(bundle).encoded(maximumBytes: maximumBytes),
                policy: point.policy,
                sourceEntries: point.entries
            )
        } catch let error as StudyProjectionJSON.Failure {
            throw error
        } catch {
            throw ServerError.internalServerError("Study data export is unavailable")
        }
    }

    static func identifier(system: String, value: String) throws -> StudyProjectionJSON {
        try .object(["system": .string(system), "value": .string(value)])
    }

    static func reference(_ address: String) throws -> StudyProjectionJSON {
        try .object(["reference": .string(address)])
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func validate(_ grants: [Grant], context: Context) throws {
        guard grants.count <= 8192 else { throw StudyProjectionJSON.Failure.outputTooLarge }
        guard !grants.isEmpty, Set(grants.map(\.id)).count == grants.count,
              let first = grants.first?.enrollment,
              grants.allSatisfy({ $0.enrollment.study == first.study && $0.enrollment.enrollment == first.enrollment }),
              CollectionMeasurementWindow.valid(context.recordedAt),
              context.enrollmentEndsAt.map(CollectionMeasurementWindow.valid) ?? true else { throw FHIRValidationClient.invalid }
    }

    private static func associating(
        _ point: StudyPointProjection.Result, grants: [Grant], studies: [StudyEnrollment: String]
    ) throws -> [StudyProjectionJSON] {
        guard let entries = point.document["entry"]?.array else { throw FHIRValidationClient.invalid }
        let original = Dictionary(uniqueKeysWithValues: point.entries.map { ($0.derivedFullURL, $0.originalFullURL) })
        return try entries.map { entry in
            guard var members = entry.object, let address = entry["fullUrl"]?.string,
                  let source = original[address], var resource = entry["resource"]?.object else { throw FHIRValidationClient.invalid }
            if resource["resourceType"]?.string == "Observation" {
                let associated = Set(grants.filter { $0.outputFullURL == source }.compactMap { studies[$0.enrollment] })
                guard !associated.isEmpty else { throw FHIRValidationClient.invalid }
                var extensions = resource["extension"]?.array ?? []
                for study in associated.sorted() {
                    extensions.append(try .object([
                        "url": .string("http://hl7.org/fhir/StructureDefinition/workflow-researchStudy"),
                        "valueReference": reference(study)
                    ]))
                }
                resource["extension"] = .array(extensions)
            }
            members["resource"] = .object(resource)
            return .object(members)
        }
    }

    private static func derivation(
        entries: [StudyProjectionJSON], grants: [Grant], context: Context, policies: [String]
    ) throws -> StudyProjectionJSON {
        let id = UUID().uuidString.lowercased()
        let targets = try entries.map { entry in
            guard let address = entry["fullUrl"]?.string else { throw FHIRValidationClient.invalid }
            return try reference(address)
        }
        let sources = try grants.sorted { $0.id.uuidString < $1.id.uuidString }.map { grant in
            try StudyProjectionJSON.object([
                "role": .string("source"),
                "what": .object(["identifier": identifier(system: context.grantSystem.rawValue, value: grant.id.uuidString.lowercased())])
            ])
        }
        let activity: StudyProjectionJSON = try .object([
            "system": .string("http://terminology.hl7.org/CodeSystem/iso-21089-lifecycle"), "code": .string("transform")
        ])
        let receiver: StudyProjectionJSON = try .object([
            "type": .string("Device"),
            "identifier": identifier(system: context.receiver.system.rawValue, value: context.receiver.value)
        ])
        let provenance: StudyProjectionJSON = try .object([
            "resourceType": .string("Provenance"), "id": .string(id), "target": .array(targets),
            "recorded": .string(timestamp(context.recordedAt)), "policy": .array(policies.map { try .string($0) }),
            "activity": .object(["coding": .array([activity])]),
            "agent": .array([.object(["who": receiver])]),
            "entity": .array(sources)
        ])
        return try .object(["fullUrl": .string("urn:uuid:" + id), "resource": provenance])
    }
}
