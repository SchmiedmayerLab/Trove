//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import Synchronization
import Testing
import TroveAPIServer
import TroveAPITypes
@testable import TroveServer
import VaporTesting


/// Approvals change outside the study lock while the validator runs; the candidate must not record a revoked one.
struct PublicationApprovalRaceTests {
    private final class Revocation: Sendable {
        let database = Mutex<(any Database)?>(nil)
    }

    @Test
    func approvalRevokedDuringValidationLeavesNoCandidate() async throws {
        let revocation = Revocation()
        let validator = FHIRValidationClient(expectedIdentity: QuestionnaireWorkerReply.identity, sendForPurpose: { purpose, bytes in
            if let database = revocation.database.withLock({ $0 }) {
                for approval in try await QuestionnaireLanguageApproval.query(on: database).filter(\.$revokedAt == nil).all() {
                    approval.revokedAt = Date()
                    approval.revokedByIssuer = TestApp.issuer
                    approval.revokedBySubject = "revoking-administrator"
                    try await approval.update(on: database)
                }
            }
            return (200, try QuestionnaireWorkerReply.body(for: bytes, purpose: purpose))
        })
        let authority = GrantorAuthorityProvider { actor in
            .init(issuer: actor.issuer, subject: actor.subject, enabled: true, roles: [TestApp.researcherRole], groups: ["/Test Group/admin"])
        }
        try await TestApp.withApp(validator: validator, grantorAuthority: authority) { app, token in
            let (study, component) = try await PublicationReadinessTests.bilingualStudy(app: app, token: token)
            let detail = try await PublicationReadinessTests.questionnaire(study, component, app: app, token: token)
            let approved = try await app.approveLanguage(study, component, sha256: detail.sha256, language: "en-US", token: token)
            #expect(approved.status == .created)
            revocation.database.withLock { $0 = app.db }
            let revision = try #require(try await Study.find(study, on: app.db)).draftRevision
            let response = try await app.sendRequest(.POST, "\(apiBasePath)/studies/\(study)/draft/validations", beforeRequest: { request in
                request.bearerAuth(token)
                request.headers.replaceOrAdd(name: "If-Match", value: "\"\(revision)\"")
            })
            #expect(response.status == .conflict)
            #expect(try await StudyPublicationCandidate.query(on: app.db).count() == 0)
        }
    }

    @Test(arguments: [String(repeating: "A", count: 64), "abc", String(repeating: "0", count: 64)])
    func malformedApprovalInputIsABadRequest(digest: String) async throws {
        let authority = GrantorAuthorityProvider { actor in
            .init(issuer: actor.issuer, subject: actor.subject, enabled: true, roles: [TestApp.researcherRole], groups: ["/Test Group/admin"])
        }
        try await TestApp.withApp(validator: QuestionnaireWorkerReply.validator(), grantorAuthority: authority) { app, token in
            let (study, component) = try await PublicationReadinessTests.bilingualStudy(app: app, token: token)
            let wellFormed = digest == String(repeating: "0", count: 64)
            let language = wellFormed ? String(repeating: "x", count: 36) : "en-US"
            let response = try await app.approveLanguage(study, component, sha256: digest, language: language, token: token)
            #expect(response.status == .badRequest)
            #expect(try await QuestionnaireLanguageApproval.query(on: app.db).count() == 0)
        }
    }

    @Test(arguments: ["contractVersion", "definitionSchemaVersion"])
    func candidatesFromAnotherContractOrSchemaAreNotCurrent(field: String) throws {
        let candidate = StudyPublicationCandidate()
        candidate.createdAt = Date().addingTimeInterval(-60)
        candidate.expiresAt = Date().addingTimeInterval(600)
        candidate.validatorIdentity = QuestionnaireWorkerReply.identity
        candidate.contractRevision = FHIRValidationClient.contractRevision
        candidate.executionCapability = QuestionnaireValidationService.executionCapability
        candidate.snapshot = try Self.snapshot(
            contractVersion: field == "contractVersion" ? "0.0.1" : FHIRValidationClient.contractVersion,
            definitionSchemaVersion: field == "definitionSchemaVersion" ? "0.0.1" : PublicationEvidence.currentDefinitionSchemaVersion
        )
        #expect(throws: ServerError.self) {
            try candidate.requireCurrentEvidence(validatorIdentity: QuestionnaireWorkerReply.identity, now: Date())
        }
        candidate.snapshot = try Self.snapshot(
            contractVersion: FHIRValidationClient.contractVersion, definitionSchemaVersion: PublicationEvidence.currentDefinitionSchemaVersion
        )
        try candidate.requireCurrentEvidence(validatorIdentity: QuestionnaireWorkerReply.identity, now: Date())
    }
}


extension PublicationApprovalRaceTests {
    private static func snapshot(contractVersion: String, definitionSchemaVersion: String) throws -> StudyPublicationCandidate.Snapshot {
        let studyID = UUID()
        return .init(
            metadata: .init(
                id: studyID,
                title: .init([.enUS: "Study"]),
                icon: .none,
                explanationText: .init([.enUS: ""]),
                shortExplanationText: .init([.enUS: ""]),
                participationCriterion: .all([])
            ),
            consent: .init(),
            visibility: .public,
            enrollmentCondition: .none,
            collectionPolicy: try .compile(studyID: studyID, revision: 1, requirements: []),
            taskPlan: .init(schedules: []),
            questionnaires: [],
            instruments: [],
            readinessFacts: StudyFixtures.completeReadinessFacts(),
            definitionSchemaVersion: definitionSchemaVersion,
            contractVersion: contractVersion
        )
    }
}
