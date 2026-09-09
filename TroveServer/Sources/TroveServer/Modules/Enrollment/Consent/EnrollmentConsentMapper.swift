//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIServer


extension Components.Schemas.ConsentRecordResponse {
    init(_ model: EnrollmentConsent) throws {
        self.init(
            id: try model.requireId().uuidString,
            enrollmentId: model.$enrollment.id.uuidString,
            revision: model.revision,
            userResponses: .init(model.userResponses),
            presentation: .init(
                presentationId: model.presentationProof.presentationID.uuidString,
                locale: model.presentationProof.locale,
                digest: model.presentationProof.digest
            ),
            acceptedEnrollmentVersion: model.acceptedEnrollmentVersion,
            createdAt: model.createdAt!  // swiftlint:disable:this force_unwrapping
        )
    }
}


extension Components.Schemas.UserResponses {
    init(_ model: UserResponses) {
        self.init(
            toggles: .init(additionalProperties: model.toggles),
            selects: .init(additionalProperties: model.selects),
            signatures: .init(additionalProperties: model.signatures.mapValues { .init($0) })
        )
    }
}


extension Components.Schemas.SignatureData {
    init(_ model: SignatureData) {
        self.init(
            name: .init(givenName: model.name.givenName, familyName: model.name.familyName),
            signature: model.signature,
            size: model.size
        )
    }
}


extension UserResponses {
    init(_ schema: Components.Schemas.UserResponses) {
        self.init(
            toggles: schema.toggles?.additionalProperties ?? [:],
            selects: schema.selects?.additionalProperties ?? [:],
            signatures: (schema.signatures?.additionalProperties ?? [:]).mapValues { SignatureData($0) }
        )
    }
}


extension SignatureData {
    init(_ schema: Components.Schemas.SignatureData) {
        self.init(
            name: PersonNameComponents(givenName: schema.name.givenName, familyName: schema.name.familyName),
            signature: schema.signature,
            size: schema.size
        )
    }
}
