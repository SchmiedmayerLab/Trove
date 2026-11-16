//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import TroveServer


struct StudyDataIdentityTests {
    @Test
    func subjectIsStableAcrossRequestsAndRevisionsButScopedToOneStudy() throws {
        let study = UUID(), enrollment = UUID()
        let first = try StudyDataIdentifiers(studyID: study).context(enrollmentID: enrollment, endsAt: nil, recordedAt: Date())
        let second = try StudyDataIdentifiers(studyID: study).context(enrollmentID: enrollment, endsAt: nil, recordedAt: Date())
        let other = try StudyDataIdentifiers(studyID: UUID()).context(enrollmentID: enrollment, endsAt: nil, recordedAt: Date())
        #expect(first.subject == second.subject && first.subject != other.subject)
        #expect(first.grantSystem != other.grantSystem)
        let original = try StudyDataIdentifiers(studyID: study).enrollment(id: enrollment, revision: 1)
        let revised = try StudyDataIdentifiers(studyID: study).enrollment(id: enrollment, revision: 2)
        #expect(original.study == revised.study && original.enrollment == revised.enrollment)
        #expect(original.protocolURL == revised.protocolURL && original.protocolVersion != revised.protocolVersion)
        #expect(throws: ServerError.self) { try StudyDataIdentifiers(studyID: study).enrollment(id: enrollment, revision: 0) }
    }

    @Test(arguments: [
        ["/Study/researcher", "/Study/data-reader"],
        ["/Study/data-reader", "/Study/researcher"],
        ["/Study/data-reader", "/Study/admin", "/Study/audit-reader"]
    ])
    func clinicalCapabilityIsExplicitAndOrderIndependent(groups: [String]) throws {
        let context = AuthContext(
            issuer: TestApp.issuer,
            subject: "reader",
            email: "reader@example.com",
            roles: [TestApp.researcherRole],
            groups: groups,
            researcherRole: TestApp.researcherRole,
            participantRole: TestApp.participantRole
        )
        #expect(context.dataReaderGroups == ["Study"])
        try AuthContext.$current.withValue(context) { try AuthContext.checkHasDataAccess(groupName: "Study") }
        let automation = AuthContext(
            issuer: TestApp.issuer,
            subject: "reader",
            email: "reader@example.com",
            roles: [TestApp.researcherRole],
            groups: groups,
            researcherRole: TestApp.researcherRole,
            participantRole: TestApp.participantRole,
            clientAccess: .delegatedDraft
        )
        AuthContext.$current.withValue(automation) {
            #expect(throws: ServerError.self) { try AuthContext.checkHasDataAccess(groupName: "Study") }
        }
    }
}
