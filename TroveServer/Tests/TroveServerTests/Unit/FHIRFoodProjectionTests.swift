//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveFHIRContract
import ModelsR4
import Testing
@testable import TroveServer


struct FHIRFoodProjectionTests {
    @Test
    func preservesIndependentNutrientIdentities() throws {
        var observation = Observation(code: CodeableConcept(), status: .init(.final))
        observation.hasMember = try [member("carbohydrate"), member("fat")]
        try FHIRFoodProjection.validate(observation)
        #expect(observation.hasMember?.count == 2)
    }

    @Test(arguments: ["empty", "duplicate", "foreign-role", "local-reference", "wrong-type", "value"])
    func rejectsAmbiguousOrUnmodeledMembership(change: String) throws {
        var observation = Observation(code: CodeableConcept(), status: .init(.final))
        var reference = try member("nutrient")
        switch change {
        case "foreign-role": reference = try member("nutrient", role: .sourceRecord)
        case "local-reference": reference = Reference(identifier: reference.identifier, reference: "urn:uuid:unrelated", type: reference.type)
        case "wrong-type": reference = Reference(identifier: reference.identifier, type: "Patient")
        case "value": observation.value = .string("unmodeled")
        default: break
        }
        observation.hasMember = change == "empty" ? [] : change == "duplicate" ? [reference, reference] : [reference]
        #expect(throws: (any Error).self) { try FHIRFoodProjection.validate(observation) }
    }

    private func member(_ value: String, role: GroveIdentifierRole = .sourceOutput) throws -> Reference {
        let identifier = try BusinessIdentifier(system: IdentifierSystem("https://example.test/nutrients"), value: value)
        return Reference(identifier: RoledIdentifier(identifier: identifier, role: role).fhirIdentifier, type: "Observation")
    }
}
