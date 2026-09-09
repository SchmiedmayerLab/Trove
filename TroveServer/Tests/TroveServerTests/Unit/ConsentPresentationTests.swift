//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import GroveFoundation
import GroveLocalization
import GroveStudyDefinition
import Testing
import TroveAPIServer
@testable import TroveServer


struct ConsentPresentationTests {
    private static func published() throws -> PublishedStudy {
        let studyID = UUID()
        return PublishedStudy(
            studyId: studyID,
            revision: 3,
            visibility: .public,
            enrollmentCondition: .none,
            metadata: .init(
                id: studyID,
                title: .init([.enUS: "Study"]),
                icon: .none,
                explanationText: .init([.enUS: "Study description"]),
                shortExplanationText: .init([.enUS: "Description"]),
                participationCriterion: .all([])
            ),
            bundleKey: "synthetic/presentation-only.zip",
            bundleDigest: String(repeating: "a", count: 64),
            artifactID: UUID(),
            consentSnapshot: .init([
                .enUS: "---\ntitle: Consent\nversion: 1.0.0\n---\n<toggle id=agree expected-value=true>Agree</toggle>"
            ]),
            collectionPolicy: try .compile(studyID: studyID, revision: 3, requirements: []),
            id: UUID()
        )
    }

    @Test
    func exactPublishedVariantDeterminesIdentityAndDigest() throws {
        let published = try Self.published()
        let presentation = try ConsentPresentation(published: published, locale: "en-US")
        let expected = "---\ntitle: Consent\nversion: 1.0.0\n---\n<toggle id=agree expected-value=true>Agree</toggle>"
        let expectedDigest = SHA256.hash(data: Data(expected.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(presentation.presentationID == published.id)
        #expect(presentation.revision == 3)
        #expect(presentation.locale == "en-US")
        #expect(presentation.markdown == expected)
        #expect(presentation.digest == expectedDigest)
        try presentation.validate(
            presentationID: presentation.presentationID,
            locale: "en-US",
            digest: expectedDigest,
            responses: .init(toggles: ["agree": true])
        )
    }

    @Test(arguments: ["en-GB", "de-DE", "en", "en_US", "en-us", ""])
    func localeDoesNotFallBackOrNormalize(requested: String) {
        #expect(throws: ServerError.self) {
            try ConsentPresentation(published: Self.published(), locale: requested)
        }
    }

    @Test(arguments: ["snapshot", "id", "zero-revision", "negative-revision"])
    func unavailableOrInvalidPublicationCannotProvidePresentation(missing: String) throws {
        let published = try Self.published()
        switch missing {
        case "snapshot": published.consentSnapshot = .init([:])
        case "id": published.id = nil
        case "zero-revision": published.revision = 0
        default: published.revision = -1
        }
        #expect(throws: ServerError.self) {
            try ConsentPresentation(published: published, locale: "en-US")
        }
    }

    @Test(arguments: ["id", "locale", "digest"])
    func alteredPresentationProofIsRejected(altered: String) throws {
        let presentation = try ConsentPresentation(published: Self.published(), locale: "en-US")
        #expect(throws: ServerError.self) {
            try presentation.validate(
                presentationID: altered == "id" ? UUID() : presentation.presentationID,
                locale: altered == "locale" ? "de-DE" : presentation.locale,
                digest: altered == "digest" ? String(repeating: "0", count: 64) : presentation.digest,
                responses: .init(toggles: ["agree": true])
            )
        }
    }

    @Test
    func matchingProofDoesNotBypassRequiredAcknowledgements() throws {
        let presentation = try ConsentPresentation(published: Self.published(), locale: "en-US")
        #expect(throws: ServerError.self) {
            try presentation.validate(
                presentationID: presentation.presentationID,
                locale: presentation.locale,
                digest: presentation.digest,
                responses: .init(toggles: ["agree": false])
            )
        }
    }

    @Test
    func resolvedPresentationIsAnIndependentValueSnapshot() throws {
        let published = try Self.published()
        let presentation = try ConsentPresentation(published: published, locale: "en-US")
        published.consentSnapshot = .init([.enUS: "Changed text"])
        let changed = try ConsentPresentation(published: published, locale: "en-US")
        #expect(presentation.markdown.contains("expected-value=true"))
        #expect(changed.digest != presentation.digest)
        try presentation.validate(
            presentationID: presentation.presentationID,
            locale: presentation.locale,
            digest: presentation.digest,
            responses: .init(toggles: ["agree": true])
        )
    }

    @Test
    func renderingPreservesExistingFrontmatterEscaping() {
        let content = ConsentContent(title: "Consent: \"Name\"\nNext", content: "Exact body\r\n")
        let markdown = ConsentPresentation.markdown(content: content)
        #expect(markdown == "---\ntitle: \"Consent: \\\"Name\\\"\\nNext\"\nversion: 1.0.0\n---\nExact body\r\n")
    }

    @Test
    func retainedMarkdownIsUsedVerbatimWithoutRendering() throws {
        let published = try Self.published()
        let retained = "---\ntitle: Original title  \nversion: 7.2.1\ncustom: retained\n---\n\nCafe\u{301}\r\nExact body  \n"
        published.consentSnapshot = .init([.enUS: retained])
        let presentation = try ConsentPresentation(published: published, locale: "en-US")
        let bytes = Data(retained.utf8)
        #expect(Data(presentation.markdown.utf8) == bytes)
        #expect(presentation.digest == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    @Test(arguments: [
        ("true", "true"),
        ("null", "null"),
        ("001", "001"),
        (" Consent ", "Consent "),
        ("Consent: details", "\"Consent: details\"")
    ])
    func existingGroveFrontmatterParsingIsLiteral(title: String, parsedTitle: String) throws {
        // A future quoted-scalar fix must be coordinated with Grove. Historical
        // presentations keep their original bytes, regardless of that renderer change.
        let markdown = ConsentPresentation.markdown(content: .init(title: title, content: "Body"))
        let metadata = try MarkdownDocument.Metadata(parsing: markdown)
        #expect(metadata.title == parsedTitle)
        #expect(metadata["version"] == "1.0.0")
    }

    @Test
    func malformedPublishedConsentFailsClosed() throws {
        let published = try Self.published()
        published.consentSnapshot = .init([.enUS: "<toggle id=agree expected-value=perhaps>Agree</toggle>"])
        #expect(throws: ServerError.self) {
            try ConsentPresentation(published: published, locale: "en-US")
        }
    }
}
