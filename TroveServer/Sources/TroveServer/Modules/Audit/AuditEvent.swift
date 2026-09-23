//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Identifiers from verified server context, never a request's asserted identity.
struct AuditActor: Sendable {
    let issuer: String
    let subject: String
}


struct AuditReceipt: Sendable {
    let id: UUID
    let occurredAt: Date
}


enum AuditError: Error, Equatable {
    case transactionRequired
    case disclosureInsideTransaction
    case unsupportedDatabase
    case invalidAction
    case invalidMetadata
    case invalidScope
}


/// Deliberately has no arbitrary metadata, error message, token, or payload field.
struct AuditEvent: Sendable {
    enum Action: String, Codable, CaseIterable, Sendable {
        case consentRecorded = "consent.recorded"
        case consentPDFDisclosure = "consent.pdf.disclosure"
        case consentRecordsDisclosure = "consent.records.disclosure"
        case collectionPlanDisclosure = "collection.plan.disclosure"
        case enrollmentWithdrawn = "enrollment.withdrawn"
        case studyPublished = "study.published"
        case studyPublicationDisclosure = "study.publication.disclosure"
        case studyDraftDeleted = "study.draft.deleted"
        case studyDraftCreated = "study.draft.created"
        case studyDraftEdited = "study.draft.edited"
        case studyDraftValidated = "study.draft.validated"
        case studyDraftDisclosure = "study.draft.disclosure"
        case delegationCreated = "delegation.created"
        case delegationRevoked = "delegation.revoked"
        case delegationDisclosure = "delegation.disclosure"
        case studyBundleDisclosure = "study.bundle.disclosure"
        case artifactDiscardScheduled = "artifact.discard.scheduled"
        case sourceRegistered = "source.registered"
        case sourceRevoked = "source.revoked"
        case clinicalEventAccepted = "clinical.event.accepted"
        case clinicalEventAttributed = "clinical.event.attributed"
        case clinicalEventReceiptDisclosure = "clinical.event.receipt.disclosure"
        case studyDataGranted = "study.data.granted"
        case studyAuditDisclosure = "study.audit.disclosure"

        var scopeKind: Scope.Kind {
            switch self {
            case .sourceRegistered, .sourceRevoked, .clinicalEventAccepted, .clinicalEventAttributed, .clinicalEventReceiptDisclosure:
                .participantSource
            case .consentRecorded, .consentPDFDisclosure, .consentRecordsDisclosure, .collectionPlanDisclosure, .enrollmentWithdrawn,
                 .studyPublished, .studyPublicationDisclosure, .studyDraftDeleted, .studyBundleDisclosure, .artifactDiscardScheduled,
                 .studyDataGranted, .studyAuditDisclosure, .studyDraftCreated, .studyDraftEdited, .studyDraftValidated,
                 .studyDraftDisclosure, .delegationCreated, .delegationRevoked, .delegationDisclosure: .study
            }
        }

        var isDisclosure: Bool {
            switch self {
            case .consentPDFDisclosure, .consentRecordsDisclosure, .collectionPlanDisclosure, .studyBundleDisclosure,
                 .clinicalEventReceiptDisclosure, .studyAuditDisclosure, .studyDraftDisclosure,
                 .delegationDisclosure, .studyPublicationDisclosure: true
            case .consentRecorded, .enrollmentWithdrawn, .studyPublished, .studyDraftDeleted, .artifactDiscardScheduled,
                 .sourceRegistered, .sourceRevoked, .clinicalEventAccepted, .clinicalEventAttributed, .studyDataGranted,
                 .studyDraftCreated, .studyDraftEdited, .studyDraftValidated, .delegationCreated, .delegationRevoked: false
            }
        }
    }

    struct Context: Sendable {
        let actor: AuditActor
        var initiator: AuditActor?
        var executingClientID: String?
        var delegationID: UUID?
        var correlationID = UUID()
        /// Actual deployment revision when available; absence is not fabricated evidence.
        var applicationRevision: String?
    }

    enum Scope: Sendable {
        case study(studyID: UUID, groupID: UUID? = nil)
        case participantSource(participantID: UUID, sourceBindingID: UUID)

        enum Kind: String, Sendable {
            case study
            case participantSource = "participant_source"
        }

        var kind: Kind {
            switch self {
            case .study: .study
            case .participantSource: .participantSource
            }
        }
    }

    struct Target: Sendable {
        let id: UUID
        var version: String?
    }

    let id = UUID()
    let occurredAt = Date()
    let context: Context
    let action: Action
    let scope: Scope
    let target: Target

    func validate() throws {
        guard action.scopeKind == scope.kind else {
            throw AuditError.invalidScope
        }
        let actors = [context.actor] + (context.initiator.map { [$0] } ?? [])
        guard actors.allSatisfy({ !$0.issuer.isEmpty && $0.issuer.utf8.count <= 2048
            && !$0.subject.isEmpty && $0.subject.utf8.count <= 255 }),
            target.version.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
            context.applicationRevision.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
            context.executingClientID.map({ !$0.isEmpty && $0.utf8.count <= 255 }) ?? true,
            context.delegationID == nil || (context.initiator != nil && context.executingClientID != nil) else {
            throw AuditError.invalidMetadata
        }
    }
}
