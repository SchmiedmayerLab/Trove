//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//


/// Note: This type is mapped from Components.Schemas.StudyDetailContent via typeOverrides in the OpenAPI generator config files.
public struct StudyDetailContent: Codable, Sendable, Hashable {
    public var title: String
    public var shortTitle: String?
    public var explanationText: String?
    public var shortExplanationText: String?

    public init(title: String, shortTitle: String? = nil, explanationText: String? = nil, shortExplanationText: String? = nil) {
        self.title = title
        self.shortTitle = shortTitle
        self.explanationText = explanationText
        self.shortExplanationText = shortExplanationText
    }
}
