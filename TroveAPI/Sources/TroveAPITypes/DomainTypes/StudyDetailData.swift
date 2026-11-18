//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//


/// Study details keyed by language, with the language they were written in.
///
/// Note: This type is mapped from Components.Schemas.StudyDetailData via typeOverrides in the OpenAPI generator config files.
public struct StudyDetailData: Hashable, Sendable {
    /// The language the details were written in; ``content`` always contains it.
    public let sourceLanguage: LanguageTag
    /// The details in each language.
    public let content: [LanguageTag: StudyDetailContent]

    /// The details in ``sourceLanguage``.
    public var source: StudyDetailContent {
        // The initializers guarantee the entry.
        content[sourceLanguage] ?? StudyDetailContent(title: "")
    }

    /// Fails unless `content` contains `sourceLanguage`.
    public init?(sourceLanguage: LanguageTag, content: [LanguageTag: StudyDetailContent]) {
        guard content[sourceLanguage] != nil else {
            return nil
        }
        self.sourceLanguage = sourceLanguage
        self.content = content
    }

    /// Details written in `sourceLanguage` only.
    public init(sourceLanguage: LanguageTag, source: StudyDetailContent) {
        self.sourceLanguage = sourceLanguage
        self.content = [sourceLanguage: source]
    }
}


extension StudyDetailData: Codable {
    private enum CodingKeys: String, CodingKey {
        case sourceLanguage
        case content
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sourceLanguage = try container.decode(LanguageTag.self, forKey: .sourceLanguage)
        let content = try container.decode([LanguageTag: StudyDetailContent].self, forKey: .content)
        guard let details = Self(sourceLanguage: sourceLanguage, content: content) else {
            throw DecodingError.dataCorruptedError(
                forKey: .content,
                in: container,
                debugDescription: "Study details must include the source language"
            )
        }
        self = details
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceLanguage, forKey: .sourceLanguage)
        try container.encode(content, forKey: .content)
    }
}
