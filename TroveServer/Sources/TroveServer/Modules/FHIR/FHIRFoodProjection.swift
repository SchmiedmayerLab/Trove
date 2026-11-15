//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveFHIRContract
import ModelsR4


/// A food correlation groups independently identified nutrients. Membership does not grant access to their values.
enum FHIRFoodProjection {
    static func validate(_ observation: Observation) throws {
        guard observation.value == nil, observation.component?.isEmpty != false,
              observation.dataAbsentReason == nil, let members = observation.hasMember,
              !members.isEmpty else { throw FHIRValidationClient.invalid }
        var identities: Set<BusinessIdentifier> = []
        for member in members {
            guard member.reference == nil, member.extension?.isEmpty != false,
                  member.type?.value?.url.absoluteString == ResourceType.observation.rawValue,
                  let identifier = member.identifier else { throw FHIRValidationClient.invalid }
            let identity = try RoledIdentifier(identifier)
            guard identity.role == .sourceOutput, identities.insert(identity.identifier).inserted else { throw FHIRValidationClient.invalid }
        }
    }
}
