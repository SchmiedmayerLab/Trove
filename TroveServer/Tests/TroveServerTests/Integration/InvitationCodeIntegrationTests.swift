//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


@Suite(.serialized)
struct InvitationCodeIntegrationTests {
    @Test
    func redemptionAfterUnusedReadPreventsDeletion() async throws {
        try await TestApp.withApp { app, _ in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyID = try study.requireId()
            let code = InvitationCode(studyId: studyID, code: "LATE-USE1")
            try await code.save(on: app.db)
            let codeID = try code.requireId()
            let repository = InvitationCodeRepository(database: app.db)
            let unused = try #require(try await repository.find(id: codeID, studyId: studyID))
            #expect(unused.enrollment == nil)

            let participant = try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: "late-redemption")
            let enrollment = Enrollment(
                participantId: try participant.requireId(), studyId: studyID, currentRevision: 1, invitationCodeId: codeID
            )
            try await enrollment.save(on: app.db)

            // Reproduce the exact stale-read ordering without timing-dependent concurrent tasks.
            await #expect {
                try await repository.delete(unused)
            } throws: { error in
                guard let error = error as? ServerError else {
                    return false
                }
                return error.status == .conflict
            }
            #expect(try await InvitationCode.find(codeID, on: app.db) != nil)
            let retained = try #require(try await Enrollment.find(enrollment.requireId(), on: app.db))
            #expect(retained.$invitationCode.id == codeID)
        }
    }

    @Test
    func listCodesEmpty() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            try await app.test(.GET, "\(apiBasePath)/studies/\(studyId)/invitation-codes", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)

                let codes = try response.content.decode([Components.Schemas.InvitationCodeResponse].self)
                #expect(codes.isEmpty)
            }
        }
    }

    @Test
    func createCodesReturnsCreated() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            try await app.test(.POST, "\(apiBasePath)/studies/\(studyId)/invitation-codes", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody(["count": 3] as [String: Any])
            }) { response in
                #expect(response.status == .created)

                let codes = try response.content.decode([Components.Schemas.InvitationCodeResponse].self)
                #expect(codes.count == 3)

                // Codes get read aloud to participants, so the alphabet deliberately leaves out
                // the glyphs that are easy to confuse: I, L, O, 0 and 1.
                let allowed = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
                for code in codes {
                    #expect(code.studyId == studyId.uuidString)
                    #expect(code.code.count == 9)
                    #expect(code.used == false)
                    #expect(code.enrollmentId == nil)

                    let parts = code.code.split(separator: "-")
                    #expect(parts.count == 2)
                    #expect(parts.allSatisfy { $0.count == 4 })
                    #expect(parts.joined().allSatisfy { allowed.contains($0) })
                }

                let uniqueCodes = Set(codes.map(\.code))
                #expect(uniqueCodes.count == 3)
            }
        }
    }

    @Test
    func createCodesWithExpiry() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            let expiresAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400))

            try await app.test(.POST, "\(apiBasePath)/studies/\(studyId)/invitation-codes", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody(["count": 1, "expiresAt": expiresAt] as [String: Any])
            }) { response in
                #expect(response.status == .created)

                let codes = try response.content.decode([Components.Schemas.InvitationCodeResponse].self)
                #expect(codes.count == 1)
                #expect(codes[0].expiresAt != nil)
            }
        }
    }

    @Test
    func listCodesReturnsAll() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            try await app.test(.POST, "\(apiBasePath)/studies/\(studyId)/invitation-codes", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody(["count": 2] as [String: Any])
            }) { _ in }

            try await app.test(.GET, "\(apiBasePath)/studies/\(studyId)/invitation-codes", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)

                let codes = try response.content.decode([Components.Schemas.InvitationCodeResponse].self)
                #expect(codes.count == 2)
            }
        }
    }

    @Test
    func deleteCodeReturnsNoContent() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            var createdCodes: [Components.Schemas.InvitationCodeResponse] = []
            try await app.test(.POST, "\(apiBasePath)/studies/\(studyId)/invitation-codes", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody(["count": 1] as [String: Any])
            }) { response in
                createdCodes = try response.content.decode([Components.Schemas.InvitationCodeResponse].self)
            }

            let codeId = createdCodes[0].id

            try await app.test(.DELETE, "\(apiBasePath)/studies/\(studyId)/invitation-codes/\(codeId)", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .noContent)
            }

            // Verify it's gone
            try await app.test(.GET, "\(apiBasePath)/studies/\(studyId)/invitation-codes", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                let codes = try response.content.decode([Components.Schemas.InvitationCodeResponse].self)
                #expect(codes.isEmpty)
            }
        }
    }

    @Test
    func deleteRedeemedCodeReturnsConflict() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            // Create a code and an enrollment that references it (simulating a redeemed code)
            let code = InvitationCode(studyId: studyId, code: "REDEEMED1")
            try await code.save(on: app.db)
            let codeId = try code.requireId()

            let participant = try await ParticipantFixtures.createParticipant(on: app.db)
            let enrollment = Enrollment(
                participantId: try participant.requireId(),
                studyId: studyId,
                currentRevision: 1,
                invitationCodeId: codeId
            )
            try await enrollment.save(on: app.db)

            try await app.test(.DELETE, "\(apiBasePath)/studies/\(studyId)/invitation-codes/\(codeId)", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .conflict)
            }
        }
    }

    @Test
    func deleteNonExistentCodeReturnsNotFound() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            let randomId = UUID()

            try await app.test(.DELETE, "\(apiBasePath)/studies/\(studyId)/invitation-codes/\(randomId)", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .notFound)
            }
        }
    }
}
