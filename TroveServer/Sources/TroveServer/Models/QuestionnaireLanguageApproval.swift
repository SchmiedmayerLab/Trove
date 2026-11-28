//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation


/// A study administrator's approval of one exact Questionnaire resource for administration in one language.
///
/// The approval names the resource by its SHA-256, so any edit leaves it without effect. It records approval;
/// it does not establish that an institution reviewed the translation.
final class QuestionnaireLanguageApproval: Model, @unchecked Sendable {
    static let schema = "questionnaire_language_approvals"

    @ID(key: .id) var id: UUID?
    @Field(key: "study_id") var studyID: UUID
    @Field(key: "component_id") var componentID: UUID
    @Field(key: "sha256") var sha256: String
    @Field(key: "language") var language: String
    @Field(key: "approved_by_issuer") var approvedByIssuer: String
    @Field(key: "approved_by_subject") var approvedBySubject: String
    @Field(key: "approved_at") var approvedAt: Date
    @OptionalField(key: "revoked_at") var revokedAt: Date?
    @OptionalField(key: "revoked_by_issuer") var revokedByIssuer: String?
    @OptionalField(key: "revoked_by_subject") var revokedBySubject: String?

    init() {}

    init(studyID: UUID, componentID: UUID, sha256: String, language: String, approver: AuditActor, approvedAt: Date) {
        self.id = UUID()
        self.studyID = studyID
        self.componentID = componentID
        self.sha256 = sha256
        self.language = language
        self.approvedByIssuer = approver.issuer
        self.approvedBySubject = approver.subject
        self.approvedAt = approvedAt
    }

    /// Approvals in force for the given resources, read on the caller's transaction.
    static func inForce(componentIDs: [UUID], on database: any Database) async throws -> [QuestionnaireLanguageApproval] {
        guard !componentIDs.isEmpty else {
            return []
        }
        return try await query(on: database)
            .filter(\.$componentID ~~ componentIDs)
            .filter(\.$revokedAt == nil)
            .sort(\.$language)
            .all()
    }
}
