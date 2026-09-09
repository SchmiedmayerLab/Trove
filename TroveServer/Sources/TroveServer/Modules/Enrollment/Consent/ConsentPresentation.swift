//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import TroveAPIServer


/// An exact localized presentation derived only from retained publication content.
struct ConsentPresentation: Sendable {
    let presentationID: UUID
    let revision: Int
    let locale: String
    let markdown: String
    let digest: String

    private let requirements: ConsentResponseRequirements

    init(published: PublishedStudy, locale: String) throws {
        guard let id = published.id, published.revision > 0 else {
            throw ServerError.conflict("An approved consent presentation is unavailable for this publication")
        }
        // Do not use LocalizationsDictionary's default subscript: it permits language
        // matching and an en-US fallback. Consent binds the exact requested variant.
        guard let markdown = published.consentSnapshot.first(where: { $0.key.description == locale })?.value else {
            throw ServerError.conflict("The requested consent presentation locale is unavailable")
        }
        let requirements: ConsentResponseRequirements
        do {
            requirements = try ConsentResponseRequirements(markdown: markdown)
        } catch {
            throw ServerError.conflict("The approved consent presentation cannot be validated")
        }
        self.presentationID = id
        self.revision = published.revision
        self.locale = locale
        self.markdown = markdown
        self.digest = SHA256.hash(data: Data(markdown.utf8)).map { String(format: "%02x", $0) }.joined()
        self.requirements = requirements
    }

    func validate(presentationID: UUID, locale: String, digest: String, responses: UserResponses) throws {
        guard presentationID == self.presentationID, locale == self.locale, digest == self.digest else {
            throw ServerError.conflict("Consent presentation does not match the reviewed publication")
        }
        do {
            try requirements.validate(responses)
        } catch {
            throw ServerError.badRequest("Consent responses do not satisfy the approved presentation")
        }
    }
}


extension ConsentPresentation {
    static func markdown(content: ConsentContent) -> String {
        "---\ntitle: \(yamlEscape(content.title))\nversion: 1.0.0\n---\n\(content.content)"
    }

    /// Preserves the existing bundle format. Grove currently reads frontmatter values
    /// literally; quoted-scalar decoding needs a coordinated Grove change, not a rewrite
    /// of retained presentations. This renderer is used only when creating publications.
    static func yamlEscape(_ value: String) -> String {
        let specialChars = ":{}[]#&*!|>'\"%@`"
        let needsQuoting = value.contains(where: { specialChars.contains($0) })
            || value.contains(where: { $0.isNewline || $0 == "\t" || $0 == "\0" })
        if !needsQuoting {
            return value
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\0", with: "\\0")
        return "\"\(escaped)\""
    }
}
