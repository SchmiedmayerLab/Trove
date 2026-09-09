//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import CryptoKit
import Foundation
import GroveConsent
import Testing
@testable import Trove
import TroveAPIClient


@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ConsentModelTests {
    @Test
    func uncertainRetryKeepsExactEvidenceAndCannotSwitchStudy() async throws {
        let fixture = Fixture()
        fixture.submissionError = .outcomeUnknown
        let model = fixture.model()
        await fixture.open(model)
        #expect(model.phase == .reviewing)
        await model.submit()
        #expect(model.phase == .retryRequired)
        await model.open(enrollmentID: "another", revision: 2, locale: "de-DE")
        #expect(model.matches(enrollmentID: fixture.enrollmentID, revision: 1, locale: "en-US"))
        #expect(fixture.presentationLoads == 1)
        fixture.submissionError = nil
        await model.retry()
        #expect(model.phase == .accepted)
        #expect(fixture.exports == 1)
        #expect(fixture.commands.count == 2)
        #expect(fixture.commands.first == fixture.commands.last)
        #expect(model.document == nil)
    }

    @Test
    func staleSubmissionRequiresExplicitReviewAndNeverResubmitsAutomatically() async {
        let fixture = Fixture()
        fixture.submissionError = .reviewRequired
        let model = fixture.model()
        await fixture.open(model)
        await model.submit()
        #expect(model.phase == .reviewRequired)
        await model.retry()
        #expect(fixture.commands.count == 1)
        await fixture.open(model)
        #expect(model.phase == .reviewing)
        #expect(fixture.commands.count == 1)
        fixture.submissionError = nil
        await model.submit()
        #expect(fixture.commands.count == 2)
        #expect(fixture.commands.first?.commandID != fixture.commands.last?.commandID)
    }

    @Test(arguments: ["en-US", "de-DE"])
    func pendingReviewSurvivesNewPublicationAndProfileLanguage(locale: String) async throws {
        let fixture = Fixture()
        fixture.value.revision = 2
        fixture.submissionError = .outcomeUnknown
        let model = fixture.model()
        await model.open(enrollmentID: fixture.enrollmentID, revision: 2, locale: "en-US")
        await model.submit()
        let original = try #require(fixture.commands.first)
        // Current enrollment remains at 1 while the latest publication advances to 3.
        fixture.value.revision = 3
        await model.open(enrollmentID: fixture.enrollmentID, revision: 1, locale: locale)
        await model.open(enrollmentID: fixture.enrollmentID, revision: 3, locale: locale)
        let pending = try #require(model.pendingReview)
        #expect(pending.enrollmentID == fixture.enrollmentID)
        #expect(pending.revision == 2)
        #expect(pending.locale == "en-US")
        await model.open(enrollmentID: pending.enrollmentID, revision: pending.revision, locale: pending.locale)
        #expect(model.matches(enrollmentID: pending.enrollmentID, revision: 2, locale: "en-US"))
        #expect(model.phase == .retryRequired)
        #expect(fixture.requestedRevisions == [2])
        fixture.submissionError = nil
        await model.retry()
        #expect(model.phase == .accepted)
        #expect(fixture.commands == [original, original])
        #expect(fixture.exports == 1)
        #expect(model.pendingReview == nil)
    }

    @Test(arguments: [Optional<String>.none, "participant", "other"])
    func pendingReviewIsImmediatelyHiddenWhenSessionChanges(subject: String?) async throws {
        let fixture = Fixture()
        fixture.submissionError = .outcomeUnknown
        let model = fixture.model()
        await fixture.open(model)
        await model.submit()
        _ = try #require(model.pendingReview)
        let issuer = try #require(fixture.session?.issuer)
        fixture.session = subject.map { .init(generation: UUID(), issuer: issuer, subject: $0) }
        // Filtering must work before the root view's session-change callback runs.
        #expect(model.pendingReview == nil)
        #expect(model.phase == .idle)
        model.synchronizeSession()
        await model.retry()
        #expect(model.pendingReview == nil)
        #expect(fixture.commands.count == 1)
    }

    @Test
    func inFlightSubmissionCanBeReopenedWithoutStartingAnotherCommand() async {
        let fixture = Fixture()
        let model = fixture.model()
        await fixture.open(model)
        #expect(model.pendingReview == nil)
        fixture.onSubmit = {
            #expect(model.phase == .submitting)
            #expect(model.pendingReview == .init(enrollmentID: fixture.enrollmentID, revision: 1, locale: "en-US"))
        }
        await model.submit()
        #expect(model.pendingReview == nil)
        #expect(fixture.commands.count == 1)
    }

    @Test(arguments: [false, true])
    func accountChangeDuringSubmissionCannotPublishReceipt(sameSubject: Bool) async throws {
        let fixture = Fixture()
        let original = try #require(fixture.session)
        fixture.onSubmit = {
            fixture.session = .init(
                generation: UUID(),
                issuer: original.issuer,
                subject: sameSubject ? original.subject : "other"
            )
        }
        let model = fixture.model()
        await fixture.open(model)
        await model.submit()
        #expect(model.phase == .idle)
        #expect(model.receipt == nil)
        model.synchronizeSession()
        await model.retry()
        #expect(fixture.commands.count == 1)
        #expect(model.document == nil)
    }

    @Test(arguments: ["digest", "locale", "revision", "version"])
    func invalidPresentationNeverCreatesDocument(field: String) async {
        let fixture = Fixture()
        switch field {
        case "digest": fixture.value.presentation.digest = String(repeating: "0", count: 64)
        case "locale": fixture.value.presentation.locale = "de-DE"
        case "revision": fixture.value.revision = 2
        default: fixture.value.enrollmentStateVersion = 0
        }
        let model = fixture.model()
        await fixture.open(model)
        #expect(model.phase == .failed)
        #expect(model.document == nil)
        await model.submit()
        #expect(fixture.commands.isEmpty)
    }

    @Test
    func restartReconcilesModernReceiptWithoutNewExportOrSubmission() async {
        let fixture = Fixture()
        let original = fixture.model()
        await fixture.open(original)
        await original.submit()
        fixture.records = original.receipt.map { [$0] } ?? []
        // Withdrawal permits reading a receipt, but not requesting a new presentation.
        fixture.presentationError = .accessDenied
        let restored = fixture.model()
        await fixture.open(restored)
        #expect(restored.phase == .accepted)
        #expect(restored.receipt == original.receipt)
        #expect(fixture.commands.count == 1)
        #expect(fixture.exports == 1)
        #expect(fixture.presentationLoads == 1)
        #expect(restored.presentation == nil)
        #expect(restored.document == nil)
    }

    @Test(arguments: ["enrollment", "proof", "locale", "digest", "version", "id"])
    func invalidHistoricalReceiptDoesNotRestoreConsent(field: String) async throws {
        let fixture = Fixture()
        let original = fixture.model()
        await fixture.open(original)
        await original.submit()
        var record = try #require(original.receipt)
        switch field {
        case "enrollment": record.enrollmentId = UUID().uuidString
        case "proof": record.presentation = nil
        case "locale": record.presentation?.locale = "de-DE"
        case "digest": record.presentation?.digest = "invalid"
        case "version": record.acceptedEnrollmentVersion = 0
        default: record.id = "invalid"
        }
        fixture.records = [record]
        let restored = fixture.model()
        await fixture.open(restored)
        #expect(restored.phase == .failed)
        #expect(restored.receipt == nil)
        #expect(restored.document == nil)
        await restored.submit()
        #expect(fixture.commands.count == 1)
        #expect(fixture.presentationLoads == 1)
    }

    @Test
    func forwardReviewSubmitsOnlyTheExplicitlyReviewedRevision() async throws {
        let fixture = Fixture()
        fixture.value.revision = 2
        fixture.value.enrollmentStateVersion = 5
        fixture.value.enrollmentETag = "\"enrollment-5\""
        let reviewed = fixture.value
        let model = fixture.model()
        await model.open(enrollmentID: fixture.enrollmentID, revision: 2, locale: "en-US")
        #expect(model.phase == .reviewing)
        // Publication can advance while the participant reviews the selected revision.
        fixture.value.revision = 3
        await model.submit()
        let command = try #require(fixture.commands.first)
        #expect(command.reviewedRevision == 2)
        #expect(command.presentation == reviewed.presentation)
        #expect(command.expectedEnrollmentVersion == 5)
        #expect(command.enrollmentETag == reviewed.enrollmentETag)
        #expect(model.receipt?.revision == 2)
        #expect(fixture.requestedRevisions == [2])
    }

    @Test
    func mismatchedReceiptLeavesOriginalCommandRetryable() async {
        let fixture = Fixture()
        fixture.alterReceipt = true
        let model = fixture.model()
        await fixture.open(model)
        await model.submit()
        #expect(model.phase == .retryRequired)
        #expect(model.receipt == nil)
        fixture.alterReceipt = false
        await model.retry()
        #expect(model.phase == .accepted)
        #expect(fixture.commands.first == fixture.commands.last)
    }
}


extension ConsentModelTests {
    @MainActor
    private final class Fixture {
        let enrollmentID = UUID().uuidString
        var session: KeycloakSessionSnapshot? = .init(
            generation: UUID(), issuer: URL(string: "https://identity.example.test/realm")!, subject: "participant"
        )
        var value: Components.Schemas.ConsentPresentationResponse
        var records: [Components.Schemas.ConsentRecordResponse] = []
        var commands: [PendingConsentCommand] = []
        var submissionError: ConsentFailure?
        var presentationError: ConsentFailure?
        var onSubmit: (() -> Void)?
        var alterReceipt = false
        var exports = 0
        var presentationLoads = 0
        var requestedRevisions: [Int] = []

        init() {
            let markdown = "Review this study."
            value = .init(
                presentation: .init(
                    presentationId: UUID().uuidString,
                    locale: "en-US",
                    digest: SHA256.hash(data: Data(markdown.utf8)).map { String(format: "%02x", $0) }.joined()
                ),
                revision: 1,
                markdown: markdown,
                enrollmentStateVersion: 1,
                enrollmentETag: "\"enrollment-1\""
            )
        }

        func open(_ model: ConsentModel) async {
            await model.open(enrollmentID: enrollmentID, revision: 1, locale: "en-US")
        }

        func model() -> ConsentModel {
            ConsentModel(transport: .init(
                session: { self.session },
                receipts: { _, _ in self.records },
                presentation: { _, _, revision, _ in
                    self.presentationLoads += 1
                    self.requestedRevisions.append(revision)
                    if let error = self.presentationError { throw error }
                    return self.value
                },
                submit: { command in
                    self.commands.append(command)
                    self.onSubmit?()
                    if let error = self.submissionError { throw error }
                    return .init(
                        id: UUID().uuidString,
                        enrollmentId: command.enrollmentID,
                        revision: command.reviewedRevision,
                        userResponses: command.responses,
                        presentation: command.presentation,
                        acceptedEnrollmentVersion: self.alterReceipt ? 99 : command.expectedEnrollmentVersion + 1,
                        createdAt: Date()
                    )
                },
                export: { _ in
                    self.exports += 1
                    return .init(responses: .init(), pdf: Data("%PDF-synthetic-\(self.exports)".utf8))
                }
            ))
        }
    }
}
