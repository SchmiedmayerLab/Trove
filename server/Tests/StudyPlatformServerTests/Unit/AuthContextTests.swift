//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

@testable import StudyPlatformServer
import Testing


@Suite
struct AuthContextTests {
    private static let researcherRole = "studyplatform-researcher"
    private static let participantRole = "studyplatform-participant"

    private func makeContext(roles: [String] = [researcherRole], groups: [String] = []) -> AuthContext {
        AuthContext(
            subject: "test",
            email: "test@example.com",
            roles: roles,
            groups: groups,
            researcherRole: Self.researcherRole,
            participantRole: Self.participantRole
        )
    }

    // MARK: - GroupRole Hierarchy

    @Test
    func adminIsGreaterThanResearcher() {
        #expect(AuthContext.GroupRole.admin > .researcher)
    }

    @Test
    func researcherIsLessThanAdmin() {
        #expect(AuthContext.GroupRole.researcher < .admin)
    }

    @Test
    func sameRolesAreEqual() {
        #expect(AuthContext.GroupRole.admin == .admin)
        #expect(AuthContext.GroupRole.researcher == .researcher)
    }

    // MARK: - Group Membership Parsing

    @Test
    func parsesValidGroupPaths() {
        let context = makeContext(groups: ["/MyGroup/admin", "/OtherGroup/researcher"])
        let memberships = context.groupMemberships

        #expect(memberships["MyGroup"] == .admin)
        #expect(memberships["OtherGroup"] == .researcher)
    }

    @Test(arguments: [
        "/GroupOnly",               // missing role segment
        "/Group/unknown",           // unrecognized role
        "",                         // empty string
        "no-leading-slash/admin",   // no leading slash
        "/Group/admin/extra",       // trailing segment
        "/"                         // slash only
    ])
    func ignoresInvalidGroupPath(path: String) {
        let context = makeContext(groups: [path])
        #expect(context.groupMemberships.isEmpty, "Expected no memberships for path: \(path)")
    }

    @Test
    func parsesGroupNameWithSpaces() {
        let context = makeContext(groups: ["/Stanford Biodesign Digital Health/admin"])
        let memberships = context.groupMemberships

        #expect(memberships["Stanford Biodesign Digital Health"] == .admin)
    }

    // MARK: - checkIsResearcher / checkIsParticipant

    @Test
    func checkIsResearcherThrowsWithNoContext() {
        #expect(throws: ServerError.self) {
            try AuthContext.checkIsResearcher()
        }
    }

    @Test
    func checkIsResearcherSucceedsWithResearcherRole() throws {
        try AuthContext.$current.withValue(makeContext(roles: [Self.researcherRole])) {
            try AuthContext.checkIsResearcher()
        }
    }

    @Test
    func checkIsResearcherFailsWithParticipantRole() {
        #expect(throws: ServerError.self) {
            try AuthContext.$current.withValue(self.makeContext(roles: [Self.participantRole])) {
                try AuthContext.checkIsResearcher()
            }
        }
    }

    @Test
    func checkIsResearcherFailsWithNoRoles() {
        #expect(throws: ServerError.self) {
            try AuthContext.$current.withValue(self.makeContext(roles: [])) {
                try AuthContext.checkIsResearcher()
            }
        }
    }

    @Test
    func checkIsParticipantSucceedsWithParticipantRole() throws {
        try AuthContext.$current.withValue(makeContext(roles: [Self.participantRole])) {
            try AuthContext.checkIsParticipant()
        }
    }

    @Test
    func checkIsParticipantFailsWithResearcherRole() {
        #expect(throws: ServerError.self) {
            try AuthContext.$current.withValue(self.makeContext(roles: [Self.researcherRole])) {
                try AuthContext.checkIsParticipant()
            }
        }
    }

    @Test
    func checkIsParticipantFailsWithNoRoles() {
        #expect(throws: ServerError.self) {
            try AuthContext.$current.withValue(self.makeContext(roles: [])) {
                try AuthContext.checkIsParticipant()
            }
        }
    }

    // MARK: - checkHasAccess

    @Test
    func checkHasAccessSucceedsForMember() throws {
        try AuthContext.$current.withValue(makeContext(groups: ["/MyGroup/researcher"])) {
            try AuthContext.checkHasAccess(groupName: "MyGroup", role: .researcher)
        }
    }

    @Test
    func checkHasAccessFailsForNonMember() {
        #expect(throws: ServerError.self) {
            try AuthContext.$current.withValue(self.makeContext(groups: ["/MyGroup/admin"])) {
                try AuthContext.checkHasAccess(groupName: "OtherGroup", role: .researcher)
            }
        }
    }

    @Test
    func checkHasAccessFailsWhenRoleInsufficient() {
        #expect(throws: ServerError.self) {
            try AuthContext.$current.withValue(self.makeContext(groups: ["/MyGroup/researcher"])) {
                try AuthContext.checkHasAccess(groupName: "MyGroup", role: .admin)
            }
        }
    }

    @Test
    func checkHasAccessSucceedsWhenAdminMeetsResearcherRequirement() throws {
        try AuthContext.$current.withValue(makeContext(groups: ["/MyGroup/admin"])) {
            try AuthContext.checkHasAccess(groupName: "MyGroup", role: .researcher)
        }
    }

    @Test
    func checkHasAccessSucceedsForExactRole() throws {
        try AuthContext.$current.withValue(makeContext(groups: ["/MyGroup/admin"])) {
            try AuthContext.checkHasAccess(groupName: "MyGroup", role: .admin)
        }
    }

    @Test
    func checkHasAccessEmptyGroupsAlwaysDenied() {
        #expect(throws: ServerError.self) {
            try AuthContext.$current.withValue(self.makeContext()) {
                try AuthContext.checkHasAccess(groupName: "AnyGroup", role: .researcher)
            }
        }
    }
}
