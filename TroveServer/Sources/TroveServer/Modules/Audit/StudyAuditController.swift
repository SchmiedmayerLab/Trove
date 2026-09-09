//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIServer


extension Controller {
    func getStudiesStudyIdAuditEvents(
        _ input: Operations.GetStudiesStudyIdAuditEvents.Input
    ) async throws -> Operations.GetStudiesStudyIdAuditEvents.Output {
        let page = try await studyService.auditPage(
            studyID: input.path.studyId.requireId(), before: input.query.before.map { try $0.requireId() }, limit: input.query.limit ?? 50
        )
        return .ok(.init(headers: .init(cacheControl: .noStore), body: .json(.init(
            studyId: page.studyID.uuidString, records: try page.records.map { try .init($0) }, nextBefore: page.nextBefore?.uuidString
        ))))
    }
}


extension Components.Schemas.StudyAuditRecord {
    init(_ record: StudyAuditRecord) throws {
        let outcome: OutcomePayload
        switch record.outcome {
        case .succeeded: outcome = .succeeded
        case .disclosureIntent: outcome = .disclosureIntent
        }
        try self.init(
            id: record.id.uuidString,
            occurredAt: record.occurredAt,
            actor: .init(issuer: record.actor.issuer, subject: record.actor.subject),
            initiator: record.initiator.map { .init(issuer: $0.issuer, subject: $0.subject) },
            action: .init(record.action),
            targetId: record.target.id.uuidString,
            targetVersion: record.target.version,
            outcome: outcome,
            correlationId: record.correlationID.uuidString,
            applicationRevision: record.applicationRevision
        )
    }
}


extension Components.Schemas.StudyAuditAction {
    // An exhaustive disclosure allowlist; splitting the mapping would obscure its coverage.
    init(_ action: AuditEvent.Action) throws { // swiftlint:disable:this cyclomatic_complexity
        switch action {
        case .consentRecorded: self = .consent_recorded
        case .consentPDFDisclosure: self = .consent_pdf_disclosure
        case .consentRecordsDisclosure: self = .consent_records_disclosure
        case .collectionPlanDisclosure: self = .collection_plan_disclosure
        case .enrollmentWithdrawn: self = .enrollment_withdrawn
        case .studyPublished: self = .study_published
        case .studyDraftDeleted: self = .study_draft_deleted
        case .studyBundleDisclosure: self = .study_bundle_disclosure
        case .artifactDiscardScheduled: self = .artifact_discard_scheduled
        case .studyDataGranted: self = .study_data_granted
        case .studyAuditDisclosure: self = .study_audit_disclosure
        case .sourceRegistered, .sourceRevoked, .clinicalEventAccepted, .clinicalEventAttributed, .clinicalEventReceiptDisclosure:
            throw AuditError.invalidScope
        }
    }
}
