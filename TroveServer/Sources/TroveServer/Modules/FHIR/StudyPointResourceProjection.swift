//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveFHIRContract


/// Fixed, declared study-point-view-v1 policy. It preserves authorized measurement content,
/// native UUIDs, readable sync identifiers and writer/conversion facts, and withholds device unit identifiers unless
/// the study receives them. It is not anonymization or free-text redaction.
struct StudyPointResourceProjection {
    private static let researchStudy = "http://hl7.org/fhir/StructureDefinition/workflow-researchStudy"
    private static let roleSystem = Canonicals.root + "/mobile/CodeSystem/grove-identifier-role"

    static var subsetTag: StudyProjectionJSON {
        get throws {
            try .object([
                "system": .string("http://terminology.hl7.org/CodeSystem/v3-ObservationValue"), "code": .string("SUBSETTED")
            ])
        }
    }

    let resources: [String: StudyProjectionJSON]
    let subject: BusinessIdentifier
    let outputs: Set<String>
    let recordingURLs: [String: String]
    let receivesDeviceUnitIdentifiers: Bool

    func resource(at address: String) throws -> StudyProjectionJSON {
        guard let original = resources[address], var resource = original.object,
              let type = original["resourceType"]?.string else { throw FHIRValidationClient.invalid }
        switch type {
        case "Observation":
            guard outputs.contains(address) else { throw FHIRValidationClient.invalid }
            try observation(&resource)
        case "DocumentReference":
            guard outputs.contains(address) else { throw FHIRValidationClient.invalid }
            try document(&resource, at: address)
        case "Device":
            try device(&resource)
        case "Provenance":
            guard let targets = resource["target"]?.array else { throw FHIRValidationClient.invalid }
            let selected = targets.filter { $0["reference"]?.string.map(outputs.contains) == true }
            guard !selected.isEmpty else { throw FHIRValidationClient.invalid }
            resource["target"] = .array(selected)
            // Producer purpose/policy annotations can name a different study. This view's
            // authority comes from exact server grants and its separate derivation Provenance.
            resource["policy"] = nil
            resource["_policy"] = nil
            resource["reason"] = nil
        default: throw FHIRValidationClient.invalid
        }
        try restrictDeviceUnits(&resource)
        try markDerived(&resource)
        return .object(resource)
    }

    private func device(_ resource: inout [String: StudyProjectionJSON]) throws {
        if resource["patient"] != nil { resource["patient"] = try participant() }
        if let identifiers = resource["identifier"]?.array {
            let retained = identifiers.filter { !isRepresentationIdentity($0) }
            resource["identifier"] = retained.isEmpty ? nil : .array(retained)
        }
    }

    private func document(_ resource: inout [String: StudyProjectionJSON], at address: String) throws {
        resource["subject"] = try participant()
        if let url = recordingURLs[address] {
            guard var contents = resource["content"]?.array, contents.count == 1,
                  var content = contents[0].object, var attachment = content["attachment"]?.object,
                  attachment["url"]?.string != nil, attachment["data"] == nil else { throw FHIRValidationClient.invalid }
            attachment["url"] = try .string(url)
            content["attachment"] = .object(attachment)
            contents[0] = .object(content)
            resource["content"] = .array(contents)
        }
        if var context = resource["context"]?.object {
            let companions = try (context["related"]?.array ?? []).compactMap { reference -> StudyProjectionJSON? in
                guard let address = reference["reference"]?.string,
                      let type = resources[address]?["resourceType"]?.string,
                      ["Observation", "DocumentReference"].contains(type) else { return nil }
                return try outputReference(address, type: type)
            }
            context["related"] = companions.isEmpty ? nil : .array(companions)
            resource["context"] = .object(context)
        }
    }

    private func observation(_ resource: inout [String: StudyProjectionJSON]) throws {
        resource["subject"] = try participant()
        if let performers = resource["performer"]?.array {
            resource["performer"] = try .array(performers.map { _ in try participant() })
        }
        if let dependencies = resource["derivedFrom"]?.array {
            resource["derivedFrom"] = try .array(dependencies.map { reference in
                if let address = reference["reference"]?.string,
                   let type = resources[address]?["resourceType"]?.string,
                   ["Observation", "DocumentReference"].contains(type) {
                    return try outputReference(address, type: type)
                }
                return try questionnaireReference(reference)
            })
        }
    }

    private func participant() throws -> StudyProjectionJSON {
        try .object([
            "type": .string("Patient"),
            "identifier": .object(["system": .string(subject.system.rawValue), "value": .string(subject.value)])
        ])
    }

    private func outputReference(_ address: String, type: String) throws -> StudyProjectionJSON {
        if outputs.contains(address) {
            return try .object(["type": .string(type), "reference": .string(address)])
        }
        let identities = resources[address]?["identifier"]?.array?.filter { identity in
            identity["type"]?["coding"]?.array?.contains {
                $0["system"]?.string == Self.roleSystem && $0["code"]?.string == "source-output"
            } == true
        } ?? []
        guard identities.count == 1, let identity = identities.first,
              let system = identity["system"]?.string, let value = identity["value"]?.string else {
            throw FHIRValidationClient.invalid
        }
        return try .object([
            "type": .string(type),
            "identifier": .object([
                "system": .string(system), "value": .string(value),
                "type": .object([
                    "coding": .array([.object(["system": .string(Self.roleSystem), "code": .string("source-output")])])
                ])
            ])
        ])
    }

    private func questionnaireReference(_ reference: StudyProjectionJSON) throws -> StudyProjectionJSON {
        let identifier: StudyProjectionJSON
        if let address = reference["reference"]?.string {
            guard let context = resources[address], context["resourceType"]?.string == "QuestionnaireResponse",
                  let identity = context["identifier"] else { throw FHIRValidationClient.invalid }
            identifier = identity
        } else {
            guard let identity = reference["identifier"] else { throw FHIRValidationClient.invalid }
            identifier = identity
        }
        // Preserve a resolvable business identity, not an ungranted response body or its display text.
        guard let system = identifier["system"]?.string, let value = identifier["value"]?.string else {
            throw FHIRValidationClient.invalid
        }
        return try .object([
            "type": .string("QuestionnaireResponse"),
            "identifier": .object(["system": .string(system), "value": .string(value)])
        ])
    }

    private func isRepresentationIdentity(_ identifier: StudyProjectionJSON) -> Bool {
        identifier["type"]?["coding"]?.array?.contains {
            $0["system"]?.string == Self.roleSystem
                && ["device-snapshot", "context-snapshot", "record-version", "record-retraction"].contains($0["code"]?.string ?? "")
        } == true
    }

    private func restrictDeviceUnits(_ resource: inout [String: StudyProjectionJSON]) throws {
        if !receivesDeviceUnitIdentifiers {
            try StudyDeviceUnitDisclosure.withhold(from: &resource)
        }
    }

    private func markDerived(_ resource: inout [String: StudyProjectionJSON]) throws {
        // A narrative can summarize fields removed from this view and cannot be filtered structurally.
        resource["text"] = nil
        resource["_id"] = nil
        // Administrative tags/source URLs can encode other-study membership. Carry forward
        // security labels, not producer identity/version/profile claims for the derived resource.
        // Original profiles remain in explicit internal lineage and original bytes stay in custody.
        var meta: [String: StudyProjectionJSON] = [:]
        meta["security"] = resource["meta"]?["security"]
        meta["tag"] = try .array([Self.subsetTag])
        resource["meta"] = .object(meta)
        if let extensions = resource["extension"]?.array {
            let removed = [
                Self.researchStudy, Canonicals.recordVersion.value?.url.absoluteString, Canonicals.contextSnapshot.value?.url.absoluteString
            ]
            let retained = extensions.filter { !removed.contains($0["url"]?.string) }
            resource["extension"] = retained.isEmpty ? nil : .array(retained)
        }
    }
}
