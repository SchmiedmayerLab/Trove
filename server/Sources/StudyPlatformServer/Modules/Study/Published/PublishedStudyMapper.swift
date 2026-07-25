//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import StudyPlatformAPIServer


extension Components.Schemas.PublishedStudyResponse {
    init(_ model: PublishedStudy) throws {
        self.init(
            id: try model.requireId().uuidString,
            studyId: model.$study.id.uuidString,
            revision: model.revision,
            visibility: model.visibility,
            publishedAt: model.createdAt!  // swiftlint:disable:this force_unwrapping
        )
    }
}

extension Components.Schemas.PublishedStudyListItem {
    init(_ model: PublishedStudy) throws {
        self.init(
            studyId: model.$study.id.uuidString,
            revision: model.revision,
            metadata: model.metadata,
            enrollmentConditions: model.enrollmentCondition
        )
    }
}
