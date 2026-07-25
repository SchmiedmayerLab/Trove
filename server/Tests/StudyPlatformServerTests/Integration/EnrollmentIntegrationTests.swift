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
struct EnrollmentIntegrationTests {
    @Test
    func listEnrollmentsEmpty() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()

            try await app.test(.GET, "\(apiBasePath)/studies/\(studyId)/enrollments", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)

                let enrollments = try response.content.decode([Components.Schemas.EnrollmentResponse].self)
                #expect(enrollments.isEmpty)
            }
        }
    }

    @Test
    func listEnrollmentsReturnsAll() async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()
            let participant = try await ParticipantFixtures.createParticipant(on: app.db)
            let participantId = try participant.requireId()

            let enrollment = Enrollment(
                participantId: participantId,
                studyId: studyId,
                currentRevision: 1
            )
            try await enrollment.save(on: app.db)

            try await app.test(.GET, "\(apiBasePath)/studies/\(studyId)/enrollments", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)

                let enrollments = try response.content.decode([Components.Schemas.EnrollmentResponse].self)
                #expect(enrollments.count == 1)
                #expect(enrollments[0].studyId == studyId.uuidString)
                #expect(enrollments[0].participantId == participantId.uuidString)
                #expect(enrollments[0].currentRevision == 1)
            }
        }
    }
}
