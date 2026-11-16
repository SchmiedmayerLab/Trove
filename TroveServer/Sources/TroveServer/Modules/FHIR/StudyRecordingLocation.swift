//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


enum StudyRecordingLocation {
    /// Origin-relative location, independent of request-host claims and storage addresses.
    static func path(studyID: UUID, grantID: UUID, versions: StudyDataQuery.Versions) -> String {
        let version = versions == .current ? "current" : "history"
        return "/\(apiBasePath)/studies/\(studyID.uuidString.lowercased())/data/recordings/\(grantID.uuidString.lowercased())?versions=\(version)"
    }
}
