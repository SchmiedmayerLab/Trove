//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

@_exported import TroveAPITypes


enum Trove {
    typealias Study = Components.Schemas.PublishedStudyListItem
    typealias Enrollment = Components.Schemas.EnrollmentResponse
    typealias Profile = Components.Schemas.ParticipantProfile
    typealias ProfileInput = Components.Schemas.ParticipantProfileInput
    typealias ProblemDetails = Components.Schemas.ProblemDetails
    typealias GenderIdentity = Components.Schemas.GenderIdentity
}
