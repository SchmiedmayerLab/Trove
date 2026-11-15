//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveFHIRContract
import ModelsR4


/// Direct clinical dependencies only. Patient/study connectivity is not collection authority.
enum FHIRClinicalDerivations {
    static func extract(resources: [String: ResourceProxy], into event: inout ValidatedExchangeEvent) throws {
        for node in event.nodes {
            switch resources[node.fullURL] {
            case .questionnaireResponse(let response):
                guard let identifier = response.identifier else { throw FHIRValidationClient.invalid }
                let identity = try BusinessIdentifier(identifier)
                event.questionnaireContexts.append(.init(
                    fullURL: node.fullURL, identifier: .init(system: identity.system.rawValue, value: identity.value)
                ))
            case .observation(let observation):
                for reference in observation.derivedFrom ?? [] {
                    if let address = try outputTarget(reference, resources: resources) {
                        event.outputDependencies.append(.init(outputFullURL: node.fullURL, targetFullURL: address, relation: .derivedFrom))
                    } else {
                        event.derivations.append(.init(outputFullURL: node.fullURL, target: try target(reference)))
                    }
                }
            case .documentReference(let document):
                for reference in document.context?.related ?? [] {
                    if let address = try outputTarget(reference, resources: resources) {
                        event.outputDependencies.append(.init(outputFullURL: node.fullURL, targetFullURL: address, relation: .related))
                    }
                }
            default: break
            }
        }
        try ClinicalGraphStore.validate(event)
    }

    static func outputTarget(_ reference: Reference, resources: [String: ResourceProxy]) throws -> String? {
        guard let address = reference.reference?.value?.string,
              let type = resources[address]?.resourceType, ["Observation", "DocumentReference"].contains(type) else {
            return nil
        }
        guard reference.identifier == nil, reference.extension?.isEmpty != false,
              reference.type == nil || reference.type?.value?.url.absoluteString == type else {
            throw FHIRValidationClient.invalid
        }
        return address
    }

    static func target(_ reference: Reference) throws -> ValidatedExchangeEvent.Derivation.Target {
        guard reference.extension?.isEmpty != false else { throw FHIRValidationClient.invalid }
        if let fullURL = reference.reference?.value?.string {
            guard reference.identifier == nil,
                  reference.type == nil || reference.type?.value?.url.absoluteString == "QuestionnaireResponse" else {
                throw FHIRValidationClient.invalid
            }
            return .local(fullURL)
        }
        guard reference.type?.value?.url.absoluteString == "QuestionnaireResponse", let value = reference.identifier else {
            throw FHIRValidationClient.invalid
        }
        let identifier = try BusinessIdentifier(value)
        return .logical(.init(system: identifier.system.rawValue, value: identifier.value))
    }
}
