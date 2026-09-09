//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import SwiftUI


struct EnrollmentConsentSection: View {
    let enrollment: Trove.Enrollment
    let latestRevision: Int
    let locale: String?
    let isEnabled: Bool
    @Binding var review: ConsentReviewView.Request?
    @Environment(ConsentModel.self) private var consent

    var body: some View {
        Section("Consent") {
            if let pending = consent.pendingReview, pending.enrollmentID == enrollment.id {
                Button {
                    review = .init(
                        enrollmentID: pending.enrollmentID,
                        revision: pending.revision,
                        locale: pending.locale,
                        adoptsRevision: pending.revision > enrollment.currentRevision
                    )
                } label: {
                    Text("Resume Pending Consent", comment: "Reopen the original consent submission whose result is not yet confirmed.")
                }
            }
            if let locale, !locale.isEmpty {
                Button("Review Consent") {
                    review = .init(enrollmentID: enrollment.id, revision: enrollment.currentRevision, locale: locale)
                }
                .disabled(!isEnabled)
                if enrollment.withdrawnAt == nil, latestRevision > enrollment.currentRevision {
                    Button("Review Revision \(latestRevision)") {
                        review = .init(enrollmentID: enrollment.id, revision: latestRevision, locale: locale, adoptsRevision: true)
                    }
                    .disabled(!isEnabled)
                    Text("A newer revision is available. Your enrollment changes only after you review and submit its consent.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Set your preferred language in your profile before reviewing consent.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
