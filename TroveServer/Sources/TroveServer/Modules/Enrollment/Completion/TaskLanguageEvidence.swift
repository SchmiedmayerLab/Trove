// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import TroveAPIServer


/// Reads the immutable publication evidence. Missing evidence cannot authorize a language.
enum TaskLanguageEvidence {
    static func approval(publication: PublishedStudy, component: UUID, digest: String, language: LanguageTag) throws -> UUID {
        let matches = publication.instruments.filter { $0.componentID == component }
        guard matches.count == 1, let instrument = matches.first, instrument.sha256 == digest else {
            throw ConsentCollectionTimeline.inconsistent
        }
        let approvals = instrument.administrationLanguages.filter { $0.language == language.rawValue }
        guard approvals.count == 1, let approval = approvals.first else {
            throw ServerError.conflict("The administration language has no publication approval")
        }
        return approval.approvalID
    }
}
