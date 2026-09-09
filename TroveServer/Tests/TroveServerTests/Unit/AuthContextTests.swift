//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Testing
@testable import TroveServer


@Suite
struct AuthContextTests {
    private static let researcherRole = "trove-researcher"
    private static let participantRole = "trove-participant"

    private func makeContext(roles: [String] = [researcherRole], groups: [String] = []) -> AuthContext {
        AuthContext(
            issuer: TestApp.issuer,
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
        "//Group/admin",            // empty leading group segment
        "///Group/admin",
        "/Group//admin",            // empty role segment
        "/Group/admin/",            // trailing separator
        "/Group/",
        "//admin",
        "/"                         // slash only
    ])
    func ignoresInvalidGroupPath(path: String) {
        let context = makeContext(groups: [path])
        #expect(context.groupMemberships.isEmpty, "Expected no memberships for path: \(path)")
    }

    @Test
    func parsesGroupNameWithSpaces() {
        let context = makeContext(groups: ["/Schmiedmayer Lab/admin"])
        let memberships = context.groupMemberships

        #expect(memberships["Schmiedmayer Lab"] == .admin)
    }

    @Test(arguments: [
        ["/MyGroup/admin", "/MyGroup/audit-reader"],
        ["/MyGroup/audit-reader", "/MyGroup/admin"],
        ["/MyGroup/admin", "/MyGroup/researcher", "/MyGroup/audit-reader"],
        ["/MyGroup/admin", "/MyGroup/audit-reader", "/MyGroup/researcher"],
        ["/MyGroup/researcher", "/MyGroup/admin", "/MyGroup/audit-reader"],
        ["/MyGroup/researcher", "/MyGroup/audit-reader", "/MyGroup/admin"],
        ["/MyGroup/audit-reader", "/MyGroup/admin", "/MyGroup/researcher"],
        ["/MyGroup/audit-reader", "/MyGroup/researcher", "/MyGroup/admin"]
    ])
    func auditCapabilityIsIndependentOfMembershipOrder(groups: [String]) throws {
        let context = makeContext(groups: groups)
        #expect(context.groupMemberships == ["MyGroup": .admin])
        #expect(context.auditReaderGroups == ["MyGroup"])
        try AuthContext.$current.withValue(context) { try AuthContext.checkHasAuditAccess(groupName: "MyGroup") }
    }

    @Test(arguments: [
        "/MyGroup/audit-reader/extra", "MyGroup/audit-reader", "/MyGroup/Audit-Reader",
        "//MyGroup/audit-reader", "///MyGroup/audit-reader", "/MyGroup//audit-reader", "/MyGroup/audit-reader/"
    ])
    func invalidAuditMembershipCannotGrantAccess(path: String) {
        let context = makeContext(groups: ["/MyGroup/admin", path])
        #expect(context.auditReaderGroups.isEmpty)
        AuthContext.$current.withValue(context) {
            #expect(throws: ServerError.self) { try AuthContext.checkHasAuditAccess(groupName: "MyGroup") }
        }
    }

    @Test(arguments: [
        ["/MyGroup/admin", "/MyGroup/researcher"],
        ["/MyGroup/researcher", "/MyGroup/admin"],
        ["/MyGroup/admin", "/MyGroup/admin", "/MyGroup/researcher"]
    ])
    func strongestExplicitRoleDoesNotDependOnOrderOrDuplicates(groups: [String]) throws {
        let context = makeContext(groups: groups)
        #expect(context.groupMemberships == ["MyGroup": .admin])
        #expect(context.auditReaderGroups.isEmpty)
        try AuthContext.$current.withValue(context) { try AuthContext.checkHasAccess(groupName: "MyGroup", role: .admin) }
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
