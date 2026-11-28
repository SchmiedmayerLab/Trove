//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIServer


extension Components.Schemas.PublishedStudyResponse {
    init(_ model: PublishedStudy) throws {
        self.init(
            id: try model.requireId().uuidString,
            studyId: model.$study.id.uuidString,
            revision: model.revision,
            visibility: model.visibility,
            publishedAt: model.createdAt!,  // swiftlint:disable:this force_unwrapping
            definitionSchemaVersion: model.definitionSchemaVersion,
            contractVersion: model.contractVersion,
            contractRevision: model.contractRevision,
            validatorIdentity: model.validatorIdentity,
            executionCapability: model.executionCapability,
            instruments: model.instruments.map { instrument in
                .init(
                    componentId: instrument.componentID.uuidString,
                    sha256: instrument.sha256,
                    language: instrument.language,
                    translationLanguages: instrument.translationLanguages,
                    administrationLanguages: instrument.administrationLanguages.map {
                        .init(language: $0.language, approvalId: $0.approvalID.uuidString, approvedAt: $0.approvedAt)
                    }
                )
            },
            unavailableCollectionRequirements: model.collectionPolicy.unavailableRequirements.map(Components.Schemas.CollectionRequirement.init)
        )
    }
}


extension Components.Schemas.StudyRouteValidation {
    init(_ route: CollectionRouteAvailability) {
        self.init(
            index: route.index,
            profile: route.requirement.profile,
            sourceKind: route.requirement.sourceKind == .participantApp ? .participantApp : .serverWorker,
            providerRegistrationId: route.requirement.providerRegistrationID?.uuidString.lowercased(),
            sourceTypeIdentifier: route.requirement.sourceTypeIdentifier,
            requirement: route.requirement.requirement == .optional ? .optional : .required,
            availability: route.available ? .available : .unavailable
        )
    }
}

extension Components.Schemas.PublishedStudyListItem {
    init(_ model: PublishedStudy) throws {
        self.init(
            studyId: model.$study.id.uuidString,
            revision: model.revision,
            bundleSha256: model.bundleDigest,
            metadata: model.metadata,
            enrollmentConditions: model.enrollmentCondition
        )
    }
}
