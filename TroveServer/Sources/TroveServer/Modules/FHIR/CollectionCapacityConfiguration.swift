//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import TroveAPITypes


struct CollectionCapacityConfiguration: Sendable {
    static let standard = Self()
    let admission: EventSubmissionLimits.Configuration
    let export: StudyExportLimits

    private init() {
        admission = .standard
        export = .standard
    }

    init(environment: [String: String]) throws {
        admission = try .init(settings: environment)
        export = try .init(
            bundleBytes: CollectionCapacitySetting.exportBundleBytes.read(from: environment, default: StudyExportLimits.standard.bundleBytes),
            pageBytes: CollectionCapacitySetting.exportPageBytes.read(from: environment, default: StudyExportLimits.standard.pageBytes)
        )
    }
}
