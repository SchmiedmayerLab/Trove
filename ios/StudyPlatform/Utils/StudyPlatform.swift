//
// This source file is part of the StudyPlatform-iOS open source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

@_exported import StudyPlatformAPITypes

enum StudyPlatform {
    typealias Study = Components.Schemas.PublishedStudyListItem
    typealias Enrollment = Components.Schemas.EnrollmentResponse
    typealias Profile = Components.Schemas.ParticipantProfile
    typealias ProfileInput = Components.Schemas.ParticipantProfileInput
    typealias ProblemDetails = Components.Schemas.ProblemDetails
    typealias GenderIdentity = Components.Schemas.GenderIdentity
}
