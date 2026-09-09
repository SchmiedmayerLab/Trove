//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveFHIRContract
import ModelsR4


/// Receiver capabilities for the initial point graph, not a second FHIR validator.
/// Clinical derivations may be scoped logical references; other supporting references remain local. Producer study annotations
/// remain context, never enrollment, consent, or collection authority.
enum FHIRPointSupportBoundary {
    private static let gatewayDevice = "http://hl7.org/fhir/StructureDefinition/observation-gatewayDevice"
    private static let researchStudy = "http://hl7.org/fhir/StructureDefinition/workflow-researchStudy"
    private static let completionMode = "http://hl7.org/fhir/StructureDefinition/questionnaireresponse-completionMode"

    static func validate(resources: [String: ResourceProxy]) throws {
        for resource in resources.values {
            guard let domain = resource.get() as? any DomainResource,
                  domain.contained?.isEmpty != false, domain.modifierExtension?.isEmpty != false,
                  domain.implicitRules == nil else { throw FHIRValidationClient.invalid }
            try extensions(domain.extension ?? [], resourceType: resource.resourceType, resources: resources)
            try supporting(resource, resources: resources)
        }
    }

    private static func supporting(_ resource: ResourceProxy, resources: [String: ResourceProxy]) throws {
        switch resource {
        case .patient(let patient):
            try patientContext(patient)
        case .observation(let observation):
            try observationContext(observation, resources: resources)
        case .questionnaireResponse(let response):
            try questionnaire(response)
        case .device(let device):
            try deviceContext(device, resources: resources)
        case .researchSubject(let subject):
            guard subject.consent == nil else { throw FHIRValidationClient.invalid }
            try literal(subject.study, type: "ResearchStudy", resources: resources)
        case .researchStudy(let study):
            try studyContext(study, resources: resources)
        case .planDefinition(let plan):
            try planContext(plan)
        case .provenance(let provenance):
            try provenanceContext(provenance, resources: resources)
        default: throw FHIRValidationClient.invalid
        }
    }

    private static func patientContext(_ patient: Patient) throws {
        guard patient.link?.isEmpty != false, patient.generalPractitioner?.isEmpty != false,
              patient.managingOrganization == nil, patient.contact?.isEmpty != false else { throw FHIRValidationClient.invalid }
    }

    private static func planContext(_ plan: PlanDefinition) throws {
        guard plan.subject == nil, plan.action?.isEmpty != false, plan.goal?.isEmpty != false,
              plan.useContext?.isEmpty != false else { throw FHIRValidationClient.invalid }
    }

    private static func observationContext(_ observation: Observation, resources: [String: ResourceProxy]) throws {
        for reference in observation.derivedFrom ?? [] {
            if case .local(let fullURL) = try FHIRClinicalDerivations.target(reference) {
                guard resources[fullURL]?.resourceType == "QuestionnaireResponse" else { throw FHIRValidationClient.invalid }
            }
        }
        if let device = observation.device { try literal(device, type: "Device", resources: resources) }
        for note in observation.note ?? [] {
            // Notes remain in the exact retained version; do not discard their attribution references.
            guard note.extension?.isEmpty != false else { throw FHIRValidationClient.invalid }
            if case .reference? = note.author { throw FHIRValidationClient.invalid }
        }
    }

    private static func deviceContext(_ device: Device, resources: [String: ResourceProxy]) throws {
        guard device.owner == nil, device.location == nil, device.definition == nil,
              device.note?.isEmpty != false else { throw FHIRValidationClient.invalid }
        if let parent = device.parent { try literal(parent, type: "Device", resources: resources) }
    }

    private static func studyContext(_ study: ResearchStudy, resources: [String: ResourceProxy]) throws {
        guard study.sponsor == nil, study.principalInvestigator == nil, study.site?.isEmpty != false,
              study.enrollment?.isEmpty != false, study.partOf?.isEmpty != false,
              study.note?.isEmpty != false else { throw FHIRValidationClient.invalid }
        for reference in study.protocol ?? [] {
            try literal(reference, type: "PlanDefinition", resources: resources)
        }
    }

    private static func provenanceContext(_ provenance: Provenance, resources: [String: ResourceProxy]) throws {
        guard provenance.location == nil, provenance.signature?.isEmpty != false else { throw FHIRValidationClient.invalid }
        for target in provenance.target { try literal(target, type: "Observation", resources: resources) }
        for agent in provenance.agent {
            try provenanceAgent(agent, resources: resources)
        }
        for entity in provenance.entity ?? [] {
            // The pinned IG validator proves the single source-record entity identity and role.
            guard entity.extension?.isEmpty != false,
                  entity.modifierExtension?.isEmpty != false,
                  entity.what.reference == nil, entity.what.identifier != nil,
                  entity.what.extension?.isEmpty != false else { throw FHIRValidationClient.invalid }
            for agent in entity.agent ?? [] {
                try provenanceAgent(agent, resources: resources)
            }
        }
    }

    private static func provenanceAgent(_ agent: ProvenanceAgent, resources: [String: ResourceProxy]) throws {
        // Converter and source-application attribution must both resolve inside this event.
        guard agent.onBehalfOf == nil, agent.extension?.isEmpty != false,
              agent.modifierExtension?.isEmpty != false else { throw FHIRValidationClient.invalid }
        try literal(agent.who, type: "Device", resources: resources)
    }

    private static func questionnaire(_ response: QuestionnaireResponse) throws {
        guard response.author == nil, response.source == nil, response.encounter == nil,
              response.basedOn?.isEmpty != false, response.partOf?.isEmpty != false else { throw FHIRValidationClient.invalid }
        try items(response.item ?? [], depth: 0)
    }

    private static func items(_ values: [QuestionnaireResponseItem], depth: Int) throws {
        guard depth <= 64 else { throw FHIRValidationClient.invalid }
        for item in values {
            guard item.extension?.isEmpty != false, item.modifierExtension?.isEmpty != false else { throw FHIRValidationClient.invalid }
            try items(item.item ?? [], depth: depth + 1)
            for answer in item.answer ?? [] {
                try scalarAnswer(answer)
                try items(answer.item ?? [], depth: depth + 1)
            }
        }
    }

    private static func scalarAnswer(_ answer: QuestionnaireResponseItemAnswer) throws {
        guard answer.extension?.isEmpty != false, answer.modifierExtension?.isEmpty != false else { throw FHIRValidationClient.invalid }
        switch answer.value {
        case .reference, .attachment: throw FHIRValidationClient.invalid
        case .quantity(let quantity):
            guard quantity.extension?.isEmpty != false else { throw FHIRValidationClient.invalid }
        case .coding(let coding):
            guard coding.extension?.isEmpty != false else { throw FHIRValidationClient.invalid }
        default: break
        }
    }

    private static func extensions(_ values: [Extension], resourceType: String, resources: [String: ResourceProxy]) throws {
        for value in values {
            guard value.extension?.isEmpty != false else { throw FHIRValidationClient.invalid }
            switch (resourceType, value.url.value?.url.absoluteString, value.value) {
            case ("Observation", gatewayDevice, .reference(let reference)):
                try literal(reference, type: "Device", resources: resources)
            case ("Observation", researchStudy, .reference(let reference)):
                try literal(reference, type: "ResearchStudy", resources: resources)
            case ("Observation", Canonicals.writerRecordVersion.value?.url.absoluteString, .string):
                break // Complete pair, canonical text and cross-output consistency are checked by the revision projection.
            case ("Observation", HealthKitContract.sourceTypeExtension.value?.url.absoluteString, .code),
                 ("Observation", Canonicals.recordingMethod.value?.url.absoluteString, .coding):
                // Full validation establishes the metadata; the location walk rejects nested extensions.
                break // Retaining acquisition context grants no collection authority.
            case ("QuestionnaireResponse", completionMode, .codeableConcept(let concept)):
                guard concept.extension?.isEmpty != false,
                      concept.coding?.allSatisfy({ $0.extension?.isEmpty != false }) != false else { throw FHIRValidationClient.invalid }
            default: throw FHIRValidationClient.invalid
            }
        }
    }

    private static func literal(_ reference: Reference, type: String, resources: [String: ResourceProxy]) throws {
        guard let target = reference.reference?.value?.string, reference.identifier == nil,
              reference.extension?.isEmpty != false,
              resources[target]?.resourceType == type else { throw FHIRValidationClient.invalid }
    }
}
