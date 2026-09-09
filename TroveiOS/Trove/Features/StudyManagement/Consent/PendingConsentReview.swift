//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

/// Navigation back to an existing submission, not permission to create a new one.
struct PendingConsentReview: Equatable {
    let enrollmentID: String
    let revision: Int
    let locale: String
}
