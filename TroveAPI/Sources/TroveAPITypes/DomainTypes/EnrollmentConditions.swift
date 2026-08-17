//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//


/// Note: This type is mapped from Components.Schemas.EnrollmentConditions via typeOverrides in the OpenAPI generator config files.
public enum EnrollmentConditions: String, Codable, Sendable {
    /// No special conditions, anyone can enroll.
    case none
    /// Enrollment requires a valid invitation code.
    case requiresInvitationCode
}
