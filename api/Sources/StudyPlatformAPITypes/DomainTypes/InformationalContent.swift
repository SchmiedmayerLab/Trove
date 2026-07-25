//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//


/// Note: This type is mapped from Components.Schemas.InformationalContent via typeOverrides in the OpenAPI generator config files.
public struct InformationalContent: Hashable, Codable, Sendable {
    public let title: String
    public let lede: String?
    public let content: String

    public init(title: String, content: String, lede: String? = nil) {
        self.title = title
        self.lede = lede
        self.content = content
    }
}
