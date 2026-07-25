//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import StudyPlatformAPIServer
@testable import StudyPlatformServer
import Testing
import VaporTesting


@Suite(.serialized)
struct InvitationCodeIntegrationTests {
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

                for code in codes {
                    #expect(code.studyId == studyId.uuidString)
                    #expect(code.code.count == 9)
                    #expect(code.code.contains("-"))
                    #expect(code.used == false)
                    #expect(code.enrollmentId == nil)
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
