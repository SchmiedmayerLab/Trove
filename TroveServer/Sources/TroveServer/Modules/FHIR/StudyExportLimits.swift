//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import TroveAPITypes


/// Export capacity is independent of current admission policy and recording download capacity.
struct StudyExportLimits: Sendable {
    static let maximumBundleBytes = 64 * 1024 * 1024
    static let maximumPageBytes = 96 * 1024 * 1024
    static let standard = Self()

    let bundleBytes: Int
    let pageBytes: Int

    private init() {
        bundleBytes = 16 * 1024 * 1024
        pageBytes = 24 * 1024 * 1024
    }

    init(bundleBytes: Int, pageBytes: Int) throws {
        guard (1...Self.maximumBundleBytes).contains(bundleBytes),
              (1024...Self.maximumPageBytes).contains(pageBytes),
              pageBytes >= ((bundleBytes + 2) / 3) * 4 + 1024 else {
            throw EventSubmissionLimits.Configuration.Failure.invalidLimits
        }
        self.bundleBytes = bundleBytes
        self.pageBytes = pageBytes
    }
}
