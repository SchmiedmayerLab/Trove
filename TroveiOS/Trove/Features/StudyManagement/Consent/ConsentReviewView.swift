//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveConsent
import GroveFoundation
import SwiftUI


struct ConsentReviewView: View {
    struct Request: Identifiable {
        let id = UUID()
        let enrollmentID: String
        let revision: Int
        let locale: String
        var adoptsRevision = false
    }

    let request: Request

    @Environment(ConsentModel.self) private var consent
    @Environment(EnrollmentModel.self) private var enrollments
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    context
                    if consent.matches(enrollmentID: request.enrollmentID, revision: request.revision, locale: request.locale) {
                        content
                    } else if consent.phase == .idle {
                        ProgressView("Loading Consent…")
                    } else {
                        Text("Resolve the pending consent review in its study before opening another review.")
                    }
                }
                .padding()
            }
            .navigationTitle("Consent Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // The initial supported document subset has no links. Keep this boundary explicit.
        .environment(\.openURL, OpenURLAction { _ in .discarded })
        .task { await open() }
        .onChange(of: consent.phase) {
            if consent.phase == .accepted {
                Task { await enrollments.refresh() }
            }
        }
    }

    private var context: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Revision \(request.revision)")
                .font(.headline)
            LabeledContent("Document Language", value: request.locale)
            Text("Consent applies to this revision and language only.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var content: some View {
        switch consent.phase {
        case .idle, .loading:
            ProgressView("Loading Consent…")
        case .reviewing:
            review
        case .submitting:
            ProgressView("Submitting Consent…")
            Text("You can close this view. Reopen it to check the result before submitting again.")
        case .retryRequired:
            message
            Text("The result is not yet confirmed. Retry sends the same signed document without creating a new consent.")
            Button("Retry Submission") { Task { await consent.retry() } }
        case .reviewRequired:
            message
            Button("Review Again") { Task { await open() } }
        case .failed:
            message
            Button("Retry Review") { Task { await open() } }
        case .accepted:
            Label("Consent Recorded", systemImage: "checkmark.circle")
                .font(.headline)
            Text("Your consent record has been saved. Enrollment status is checked separately and may have changed.")
        }
    }

    @ViewBuilder private var review: some View {
        if let document = consent.document, let date = consent.reviewDate {
            if request.adoptsRevision {
                Text("Submitting this consent will update your enrollment to revision \(request.revision).")
            }
            if let title = document.metadata.title, !title.isEmpty {
                Text(verbatim: title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
            }
            ConsentDocumentView(consentDocument: document, consentSignatureDate: date)
                .disabled(consent.isBusy)
            Button("Submit Consent") { Task { await consent.submit() } }
                .buttonStyle(.borderedProminent)
                .disabled(document.completionState != .complete || consent.isBusy)
        }
        message
    }

    @ViewBuilder private var message: some View {
        if let message = consent.errorMessage {
            Text(message)
                .foregroundStyle(.secondary)
        }
    }

    private func open() async {
        await consent.open(enrollmentID: request.enrollmentID, revision: request.revision, locale: request.locale)
        if consent.phase == .accepted {
            await enrollments.refresh()
        }
    }
}
