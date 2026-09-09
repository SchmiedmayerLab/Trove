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
                    fullURL: node.fullURL, identifier: .init(system: identity.systemValue, value: identity.value)
                ))
            case .observation(let observation):
                for reference in observation.derivedFrom ?? [] {
                    event.derivations.append(.init(outputFullURL: node.fullURL, target: try target(reference)))
                }
            default: break
            }
        }
        try ClinicalGraphStore.validate(event)
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
        return .logical(.init(system: identifier.systemValue, value: identifier.value))
    }
}
