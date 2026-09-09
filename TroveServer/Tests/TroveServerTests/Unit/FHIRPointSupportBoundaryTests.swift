//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import ModelsR4
import Testing
@testable import TroveServer


/// Mutated resources exercise only the receiver capability gate, not complete IG admission.
struct FHIRPointSupportBoundaryTests {
    enum AgentLocation: CaseIterable {
        case converter, sourceApplication
    }

    enum UnsupportedAgent: CaseIterable {
        case foreignParticipant, unresolvedDevice, nonDevice, delegation, identifierAlias, nestedExtension, modifierExtension
    }

    @Test
    func retainsTheSupportedPointGraph() throws {
        try FHIRPointSupportBoundary.validate(resources: resources())
        try FHIRPointSupportBoundary.validateExtensionLocations(in: bytes())
    }

    @Test(arguments: [HealthKitContract.sourceTypeExtension, Canonicals.recordingMethod])
    func acquisitionMetadataCannotIntroduceReferences(url: FHIRPrimitive<FHIRURI>) throws {
        let injected: [String: Any] = [
            "url": try #require(url.value?.url.absoluteString), "valueReference": Self.foreignPatient
        ]
        let values = try resources(type: "Observation", field: "extension", value: [injected])
        #expect(throws: ServerError.self) { try FHIRPointSupportBoundary.validate(resources: values) }
    }

    @Test(arguments: AgentLocation.allCases, UnsupportedAgent.allCases)
    func provenanceAgentsCannotIntroduceExternalAuthority(location: AgentLocation, unsupported: UnsupportedAgent) throws {
        var values = try resources()
        let entry = try #require(values.first { $0.value.resourceType == "Provenance" })
        var provenance = try #require(entry.value.get() as? Provenance)
        let device = try #require(values.first { $0.value.resourceType == "Device" }?.key)
        let patient = try #require(values.first { $0.value.resourceType == "Patient" }?.key)
        var agent = ProvenanceAgent(who: Reference(reference: device.asFHIRStringPrimitive()))
        let foreign = Reference(identifier: Identifier(system: "urn:other-participants", value: "other"), type: "Patient")
        let injected = Extension(url: "https://example.invalid/alternate-patient", value: .reference(foreign))
        switch unsupported {
        case .foreignParticipant: agent.who = foreign
        case .unresolvedDevice: agent.who = Reference(reference: "urn:uuid:00000000-0000-0000-0000-000000000001")
        case .nonDevice: agent.who = Reference(reference: patient.asFHIRStringPrimitive())
        case .delegation: agent.onBehalfOf = foreign
        case .identifierAlias:
            agent.who = Reference(identifier: foreign.identifier, reference: device.asFHIRStringPrimitive())
        case .nestedExtension: agent.extension = [injected]
        case .modifierExtension: agent.modifierExtension = [injected]
        }
        switch location {
        case .converter: provenance.agent = [agent]
        case .sourceApplication:
            var entity = try #require(provenance.entity?.first)
            entity.agent = [agent]
            provenance.entity = [entity]
        }
        values[entry.key] = .provenance(provenance)
        #expect(throws: ServerError.self) { try FHIRPointSupportBoundary.validate(resources: values) }
    }

    @Test(arguments: ["author", "source"])
    func alternateQuestionnaireParticipantReferencesAreRejected(field: String) throws {
        let values = try resources(type: "QuestionnaireResponse", field: field, value: Self.foreignPatient)
        #expect(throws: ServerError.self) { try FHIRPointSupportBoundary.validate(resources: values) }
    }

    @Test(arguments: ["valueReference", "valueAttachment"])
    func referenceAndAttachmentAnswersAreNotPointSupport(field: String) throws {
        let value: [String: Any] = field == "valueReference" ? Self.foreignPatient : ["url": "https://example.invalid/clinical-record"]
        let items: [[String: Any]] = [["linkId": "nested", "item": [["linkId": "answer", "answer": [[field: value]]]]]]
        let values = try resources(type: "QuestionnaireResponse", field: "item", value: items)
        #expect(throws: ServerError.self) { try FHIRPointSupportBoundary.validate(resources: values) }
    }

    @Test(arguments: [
        "Patient", "Device", "Observation", "QuestionnaireResponse", "ResearchSubject", "ResearchStudy", "PlanDefinition", "Provenance"
    ])
    func unknownReferenceExtensionsAreRejected(type: String) throws {
        let injected: [String: Any] = [
            "url": "https://example.invalid/alternate-patient", "valueReference": Self.foreignPatient
        ]
        let values = try resources(type: type, field: "extension", value: [injected])
        #expect(throws: ServerError.self) { try FHIRPointSupportBoundary.validate(resources: values) }
    }

    @Test
    func containedClinicalResourcesAreRejected() throws {
        let values = try resources(type: "Observation", field: "contained", value: [["resourceType": "Patient", "id": "other"]])
        #expect(throws: ServerError.self) { try FHIRPointSupportBoundary.validate(resources: values) }
    }

    @Test
    func logicalClinicalDerivationCanRemainPending() throws {
        let reference: [String: Any] = [
            "type": "QuestionnaireResponse", "identifier": ["system": "https://example.invalid/responses", "value": "external"]
        ]
        let values = try resources(type: "Observation", field: "derivedFrom", value: [reference])
        try FHIRPointSupportBoundary.validate(resources: values)
    }

    @Test
    func nestedAnswerExtensionsAreRejected() throws {
        let injected: [String: Any] = ["url": "https://example.invalid/alternate-patient", "valueReference": Self.foreignPatient]
        let quantity: [String: Any] = ["value": 72, "extension": [injected]]
        let item: [String: Any] = ["linkId": "answer", "answer": [["valueQuantity": quantity]]]
        let values = try resources(type: "QuestionnaireResponse", field: "item", value: [item])
        #expect(throws: ServerError.self) { try FHIRPointSupportBoundary.validate(resources: values) }
    }

    @Test
    func producerConsentReferencesDoNotBecomeAuthority() throws {
        let values = try resources(type: "ResearchSubject", field: "consent", value: [
            "type": "Consent", "identifier": ["system": "https://example.invalid/consents", "value": "producer-claim"]
        ])
        #expect(throws: ServerError.self) { try FHIRPointSupportBoundary.validate(resources: values) }
    }

    @Test(arguments: [
        "https://example.invalid/alternate-patient",
        "http://hl7.org/fhir/StructureDefinition/observation-gatewayDevice"
    ])
    func primitiveExtensionsCannotHideLogicalPatientReferences(url: String) throws {
        let injected: [String: Any] = ["url": url, "valueReference": Self.foreignPatient]
        let quantity: [String: Any] = ["value": 72, "_value": ["extension": [injected]]]
        let data = try bytes(type: "Observation", field: "valueQuantity", value: quantity)
        #expect(throws: ServerError.self) { try FHIRPointSupportBoundary.validateExtensionLocations(in: data) }
    }

    @Test(arguments: ["modifierExtension", "extension"])
    func nestedModifiersAndEmptyExtensionArraysAreRejected(field: String) throws {
        let quantity: [String: Any] = ["value": 72, "_value": [field: []]]
        let data = try bytes(type: "Observation", field: "valueQuantity", value: quantity)
        #expect(throws: ServerError.self) { try FHIRPointSupportBoundary.validateExtensionLocations(in: data) }
    }

    @Test
    func metadataWalkBoundsSizeAndNesting() {
        let nested = "{\"other\":" + String(repeating: "[", count: 64) + "0" + String(repeating: "]", count: 64) + "}"
        for data in [Data(nested.utf8), Data(repeating: 0x20, count: ValidatedQuantityLexemes.maximumBytes + 1), Data("{".utf8)] {
            #expect(throws: ServerError.self) { try FHIRPointSupportBoundary.validateExtensionLocations(in: data) }
        }
    }
}


extension FHIRPointSupportBoundaryTests {
    private static var foreignPatient: [String: Any] {
        ["type": "Patient", "identifier": ["system": "https://example.invalid/participants", "value": "other-participant"]]
    }

    private func resources(type: String? = nil, field: String = "", value: Any? = nil) throws -> [String: ResourceProxy] {
        let bundle = try JSONDecoder().decode(ModelsR4.Bundle.self, from: bytes(type: type, field: field, value: value))
        var result: [String: ResourceProxy] = [:]
        for entry in bundle.entry ?? [] {
            let fullURL = try #require(entry.fullUrl?.value?.url.absoluteString)
            let resource = try #require(entry.resource)
            result[fullURL] = resource
        }
        return result
    }

    private func bytes(type: String? = nil, field: String = "", value: Any? = nil) throws -> Data {
        let url = try #require(Foundation.Bundle.module.url(forResource: "ImmutablePointEvent", withExtension: "json"))
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try #require(document["entry"] as? [[String: Any]])
        if let type {
            let index = try #require(entries.firstIndex { ($0["resource"] as? [String: Any])?["resourceType"] as? String == type })
            var resource = try #require(entries[index]["resource"] as? [String: Any])
            resource[field] = value
            entries[index]["resource"] = resource
            document["entry"] = entries
        }
        return try JSONSerialization.data(withJSONObject: document)
    }
}
