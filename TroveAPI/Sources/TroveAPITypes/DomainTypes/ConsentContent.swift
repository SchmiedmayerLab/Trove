//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//


/// Note: This type is mapped from Components.Schemas.StudyConsent via typeOverrides in the OpenAPI generator config files.
public struct ConsentContent: Codable, Sendable, Hashable {
    public var title: String
    public var content: String

    public init(title: String = "", content: String = "") {
        self.title = title
        self.content = content
    }
}
