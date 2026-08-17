//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//


/// Note: This type is mapped from Components.Schemas.StudyVisibility via typeOverrides in the OpenAPI generator config files.
public enum StudyVisibility: String, Codable, Sendable {
    /// Listed in public study browsing.
    case `public`
    /// Only accessible via an invitation code.
    case unlisted
}
