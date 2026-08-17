//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveAccount
import GroveLocalization
import GroveStudyDefinition
import SwiftUI


struct EnrollmentView: View {
    let item: Trove.Study

    @Environment(EnrollmentModel.self) private var enrollments
    @Environment(Account.self) private var account: Account?

    @State private var isPresentingWithdrawConfirmation = false
    @State private var enteredInvitationCode: String = ""

    var body: some View {
        Form {
            Section {
                header
            }
            explanationSections
            criteriaSection
            detailsSection
            enrollmentSection
            invitationSection
            Section {
                actionButton
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if case .idle = enrollments.state {
                await enrollments.refresh()
            }
        }
        .confirmationDialog(
            "Withdraw from this study?",
            isPresented: $isPresentingWithdrawConfirmation,
            titleVisibility: .visible
        ) {
            Button("Withdraw", role: .destructive) {
                performWithdraw()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can re-enroll later if you choose.")
        }
    }

    @ViewBuilder private var explanationSections: some View {
        if !shortExplanation.isEmpty {
            Section("Summary") {
                Text(shortExplanation)
            }
        }
        if !longExplanation.isEmpty {
            Section("About this study") {
                Text(longExplanation)
            }
        }
    }

    private var criteriaSection: some View {
        Section {
            ParticipationCriteriaView(
                criterion: item.metadata.participationCriterion,
                environment: evaluationEnvironment
            )
        } header: {
            Text("Participation Criteria")
        } footer: {
            Text(meetsParticipationCriteria
                ? "You meet the participation criteria for this study."
                : "You do not currently meet the participation criteria for this study.")
        }
    }

    private var detailsSection: some View {
        Section("Details") {
            LabeledContent("Revision", value: "\(item.revision)")
            LabeledContent("Study ID") {
                Text(item.studyId)
                    .font(.footnote.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if item.metadata.consentFileRef != nil {
                LabeledContent("Consent", value: "Required")
            }
            if let dependencyId = item.metadata.studyDependency {
                LabeledContent("Requires study", value: dependencyId.uuidString)
            }
        }
    }

    @ViewBuilder private var enrollmentSection: some View {
        if let enrollment = enrollments.latestEnrollment(forStudy: item.studyId) {
            Section("Enrollment") {
                LabeledContent("Status", value: statusText(for: enrollment))
                LabeledContent("Enrolled since", value: enrollment.enrolledAt, format: .dateTime)
                if let withdrawnAt = enrollment.withdrawnAt {
                    LabeledContent("Withdrawn on", value: withdrawnAt, format: .dateTime)
                }
                LabeledContent("Current revision", value: "\(enrollment.currentRevision)")
            }
        }
    }

    @ViewBuilder private var invitationSection: some View {
        if showInvitationCodeField {
            Section {
                TextField("Invitation code (optional)", text: $enteredInvitationCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Invitation")
            } footer: {
                Text("Enter a code if this study requires one.")
            }
        }
    }

    @ViewBuilder private var actionButton: some View {
        if activeEnrollment != nil {
            Button("Withdraw from Study", role: .destructive) {
                isPresentingWithdrawConfirmation = true
            }
        } else if let latest = enrollments.latestEnrollment(forStudy: item.studyId), latest.withdrawnAt != nil {
            Text("You have withdrawn from this study and cannot enroll again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        } else {
            Button("Enroll") { performEnroll() }
        }
    }


    private var showInvitationCodeField: Bool {
        guard item.enrollmentConditions == .requiresInvitationCode else {
            return false
        }
        if activeEnrollment != nil {
            return false
        }
        if let latest = enrollments.latestEnrollment(forStudy: item.studyId), latest.withdrawnAt != nil {
            return false
        }
        return true
    }


    private var activeEnrollment: Trove.Enrollment? {
        enrollments.activeEnrollment(forStudy: item.studyId)
    }

    private var header: some View {
        HStack(spacing: 16) {
            iconView
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.bold())
                    .lineLimit(2)
                if !shortTitle.isEmpty, shortTitle != title {
                    Text(shortTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var iconView: some View {
        switch item.metadata.icon {
        case .systemSymbol(let name):
            Image(systemName: name)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
        case .custom(let url):
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "book.closed")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        case .none:
            Image(systemName: "book.closed")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
        }
    }

    private var title: String {
        item.metadata.title[.currentOrDefault] ?? item.studyId
    }

    private var shortTitle: String {
        item.metadata.shortTitle[.currentOrDefault] ?? ""
    }

    private var shortExplanation: String {
        item.metadata.shortExplanationText[.currentOrDefault] ?? ""
    }

    private var longExplanation: String {
        item.metadata.explanationText[.currentOrDefault] ?? ""
    }

    private var evaluationEnvironment: StudyDefinition.ParticipationCriterion.EvaluationEnvironment {
        let details = account?.details
        let age: Int? = details?.dateOfBirth.flatMap { dob in
            Calendar.current.dateComponents([.year], from: dob, to: .now).year
        }
        let region: Locale.Region? = details?.region.flatMap { code in
            code.isEmpty ? nil : Locale.Region(code)
        }
        let language: Locale.Language = {
            if let code = details?.language, !code.isEmpty {
                return Locale.Language(identifier: code)
            }
            return Locale.current.language
        }()
        return .init(age: age, region: region, language: language, enabledCustomKeys: [])
    }

    private var meetsParticipationCriteria: Bool {
        item.metadata.participationCriterion.evaluate(evaluationEnvironment)
    }

    private func statusText(for enrollment: Trove.Enrollment) -> String {
        enrollment.withdrawnAt == nil ? "Active" : "Withdrawn"
    }
    private func performEnroll() {
        let trimmed = enteredInvitationCode.trimmingCharacters(in: .whitespaces)
        let code: String? = trimmed.isEmpty ? nil : trimmed
        catchingTask {
            try await enrollments.enroll(studyId: item.studyId, invitationCode: code)
        }
    }
    private func performWithdraw() {
        guard let enrollment = activeEnrollment else {
            return
        }
        catchingTask {
            try await enrollments.withdraw(enrollmentId: enrollment.id)
        }
    }
}
