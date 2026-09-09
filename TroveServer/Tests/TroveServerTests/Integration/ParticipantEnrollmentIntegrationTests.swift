//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_length

import Foundation
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


@Suite(.serialized)
struct ParticipantEnrollmentIntegrationTests { // swiftlint:disable:this type_body_length
    private static let participantSubject = "enrollment-test-participant"

    // MARK: - Enroll

    @Test
    func enrollReturnsCreated() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.participantSubject)) { app, token in
            let (studyId, _) = try await setUpPublishedStudy(on: app)
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.participantSubject)

            try await app.test(.POST, "\(apiBasePath)/participant/studies/\(studyId)/enrollments", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody([String: String]())
                            }) { response in
                #expect(response.status == .created)

                let enrollment = try response.content.decode(Components.Schemas.EnrollmentResponse.self)
                #expect(enrollment.studyId == studyId.uuidString)
                #expect(enrollment.currentRevision == 1)
                #expect(enrollment.withdrawnAt == nil)
            }
        }
    }

    @Test
    func enrollDuplicateReturnsConflict() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.participantSubject)) { app, token in
            let (studyId, _) = try await setUpPublishedStudy(on: app)
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.participantSubject)

            try await app.test(.POST, "\(apiBasePath)/participant/studies/\(studyId)/enrollments", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody([String: String]())
                            }) { response in
                #expect(response.status == .created)
            }

            try await app.test(.POST, "\(apiBasePath)/participant/studies/\(studyId)/enrollments", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody([String: String]())
                            }) { response in
                #expect(response.status == .conflict)
            }
        }
    }

    @Test
    func enrollNoPublishedStudyReturnsNotFound() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.participantSubject)) { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.participantSubject)

            try await app.test(.POST, "\(apiBasePath)/participant/studies/\(studyId)/enrollments", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody([String: String]())
                            }) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test
    func enrollWithInvitationCodeReturnsCreated() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.participantSubject)) { app, token in
            let (studyId, _) = try await setUpPublishedStudy(on: app, enrollmentCondition: .requiresInvitationCode)
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.participantSubject)

            let code = InvitationCode(studyId: studyId, code: "ENRL-CODE")
            try await code.save(on: app.db)

            try await app.test(.POST, "\(apiBasePath)/participant/studies/\(studyId)/enrollments", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody(["invitationCode": "ENRL-CODE"])
            }) { response in
                #expect(response.status == .created)
            }
        }
    }

    @Test
    func enrollWithoutRequiredCodeReturnsBadRequest() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.participantSubject)) { app, token in
            let (studyId, _) = try await setUpPublishedStudy(on: app, enrollmentCondition: .requiresInvitationCode)
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.participantSubject)

            try await app.test(.POST, "\(apiBasePath)/participant/studies/\(studyId)/enrollments", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody([String: String]())
                            }) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test
    func enrollWithExpiredCodeReturnsBadRequest() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.participantSubject)) { app, token in
            let (studyId, _) = try await setUpPublishedStudy(on: app, enrollmentCondition: .requiresInvitationCode)
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.participantSubject)

            let code = InvitationCode(studyId: studyId, code: "EXPIRED-CODE", expiresAt: Date().addingTimeInterval(-3600))
            try await code.save(on: app.db)

            try await app.test(.POST, "\(apiBasePath)/participant/studies/\(studyId)/enrollments", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody(["invitationCode": "EXPIRED-CODE"])
            }) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test
    func enrollWithRedeemedCodeReturnsBadRequest() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.participantSubject)) { app, token in
            let (studyId, _) = try await setUpPublishedStudy(on: app, enrollmentCondition: .requiresInvitationCode)

            let otherParticipant = try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: "other-participant")
            let code = InvitationCode(studyId: studyId, code: "USED-CODE")
            try await code.save(on: app.db)

            // Simulate another participant having redeemed this code
            let enrollment = Enrollment(
                participantId: try otherParticipant.requireId(),
                studyId: studyId,
                currentRevision: 1,
                invitationCodeId: try code.requireId()
            )
            try await enrollment.save(on: app.db)

            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.participantSubject)

            try await app.test(.POST, "\(apiBasePath)/participant/studies/\(studyId)/enrollments", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody(["invitationCode": "USED-CODE"])
            }) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    // MARK: - List Enrollments

    @Test
    func listEnrollmentsEmpty() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.participantSubject)) { app, token in
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.participantSubject)

            try await app.test(.GET, "\(apiBasePath)/participant/enrollments", beforeRequest: { req in
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
        try await TestApp.withApp(token: .participant(subject: Self.participantSubject)) { app, token in
            let (studyId, _) = try await setUpPublishedStudy(on: app)
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.participantSubject)

            try await app.test(.POST, "\(apiBasePath)/participant/studies/\(studyId)/enrollments", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody([String: String]())
                            }) { _ in }

            try await app.test(.GET, "\(apiBasePath)/participant/enrollments", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)

                let enrollments = try response.content.decode([Components.Schemas.EnrollmentResponse].self)
                #expect(enrollments.count == 1)
            }
        }
    }

    // MARK: - Retired Consent-Free Upgrade

    @Test(arguments: [1, 2, 3])
    func retiredUpgradeRouteCannotChangeEnrollment(revision: Int) async throws {
        try await TestApp.withApp(token: .participant(subject: Self.participantSubject)) { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: try group.requireId())
            let studyId = try study.requireId()
            try await PublishedStudyFixtures.createPublishedStudy(on: app.db, studyId: studyId, revision: 1)
            try await PublishedStudyFixtures.createPublishedStudy(on: app.db, studyId: studyId, revision: 2)

            let participant = try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.participantSubject)
            let enrollment = Enrollment(
                participantId: try participant.requireId(),
                studyId: studyId,
                currentRevision: 1
            )
            try await enrollment.save(on: app.db)
            let enrollmentId = try enrollment.requireId().uuidString

            try await app.test(.PATCH, "\(apiBasePath)/participant/enrollments/\(enrollmentId)", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody(["revision": revision])
            }) { response in
                #expect(response.status == .notFound)
            }
            let unchanged = try #require(try await Enrollment.find(try enrollment.requireId(), on: app.db))
            #expect(unchanged.currentRevision == 1)
            #expect(unchanged.stateVersion == 1)
            #expect(unchanged.withdrawnAt == nil)
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 0)
        }
    }

    // MARK: - Withdraw

    @Test
    func withdrawReturnsOk() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.participantSubject)) { app, token in
            let (studyId, _) = try await setUpPublishedStudy(on: app)
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.participantSubject)

            var enrollmentId: String = ""
            try await app.test(.POST, "\(apiBasePath)/participant/studies/\(studyId)/enrollments", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody([String: String]())
                            }) { response in
                let enrollment = try response.content.decode(Components.Schemas.EnrollmentResponse.self)
                enrollmentId = enrollment.id
            }

            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(enrollmentId)/withdraw", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)

                let enrollment = try response.content.decode(Components.Schemas.EnrollmentResponse.self)
                #expect(enrollment.withdrawnAt != nil)
            }
        }
    }

    @Test
    func withdrawAlreadyWithdrawnReturnsConflict() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.participantSubject)) { app, token in
            let (studyId, _) = try await setUpPublishedStudy(on: app)
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.participantSubject)

            var enrollmentId: String = ""
            try await app.test(.POST, "\(apiBasePath)/participant/studies/\(studyId)/enrollments", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody([String: String]())
                            }) { response in
                let enrollment = try response.content.decode(Components.Schemas.EnrollmentResponse.self)
                enrollmentId = enrollment.id
            }

            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(enrollmentId)/withdraw", beforeRequest: { req in
                req.bearerAuth(token)
            }) { _ in }

            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(enrollmentId)/withdraw", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .conflict)
            }
        }
    }

    @Test
    func withdrawNotFoundReturnsNotFound() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.participantSubject)) { app, token in
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.participantSubject)

            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(UUID())/withdraw", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    // MARK: - Cross-Participant Access

    @Test
    func otherParticipantCannotWithdrawEnrollment() async throws {
        let otherSubject = "other-participant"
        try await TestApp.withApp(token: .participant(subject: otherSubject)) { app, token in
            let (studyId, _) = try await setUpPublishedStudy(on: app)

            let participantA = try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.participantSubject)
            let enrollment = Enrollment(participantId: try participantA.requireId(), studyId: studyId, currentRevision: 1)
            try await enrollment.save(on: app.db)
            let enrollmentId = try enrollment.requireId()

            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: otherSubject)

            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(enrollmentId)/withdraw", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test
    func otherParticipantCannotListConsents() async throws {
        let otherSubject = "other-participant"
        try await TestApp.withApp(token: .participant(subject: otherSubject)) { app, token in
            let (studyId, _) = try await setUpPublishedStudy(on: app)

            let participantA = try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.participantSubject)
            let enrollment = Enrollment(participantId: try participantA.requireId(), studyId: studyId, currentRevision: 1)
            try await enrollment.save(on: app.db)
            let enrollmentId = try enrollment.requireId()

            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: otherSubject)

            try await app.test(.GET, "\(apiBasePath)/participant/enrollments/\(enrollmentId)/consents", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test
    func otherParticipantCannotReadConsentPresentation() async throws {
        let otherSubject = "other-participant"
        try await TestApp.withApp(token: .participant(subject: otherSubject)) { app, token in
            let (studyId, _) = try await setUpPublishedStudy(on: app)
            let owner = try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.participantSubject)
            let enrollment = Enrollment(participantId: try owner.requireId(), studyId: studyId, currentRevision: 1)
            try await enrollment.save(on: app.db)
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: otherSubject)
            let enrollmentID = try enrollment.requireId()
            try await app.test(
                .GET,
                "\(apiBasePath)/participant/enrollments/\(enrollmentID)/consent-presentation?locale=en-US",
                beforeRequest: { $0.bearerAuth(token) }
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    // MARK: - Consents

    @Test
    func listConsentsEmpty() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.participantSubject)) { app, token in
            let (studyId, _) = try await setUpPublishedStudy(on: app)
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.participantSubject)

            var enrollmentId: String = ""
            try await app.test(.POST, "\(apiBasePath)/participant/studies/\(studyId)/enrollments", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody([String: String]())
                            }) { response in
                let enrollment = try response.content.decode(Components.Schemas.EnrollmentResponse.self)
                enrollmentId = enrollment.id
            }

            try await app.test(.GET, "\(apiBasePath)/participant/enrollments/\(enrollmentId)/consents", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)

                let consents = try response.content.decode([Components.Schemas.ConsentRecordResponse].self)
                #expect(consents.isEmpty)
            }
        }
    }

    @Test
    func createConsentReturnsCreated() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.participantSubject)) { app, token in
            let (studyId, _) = try await setUpPublishedStudy(on: app)
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.participantSubject)

            var enrollmentId: String = ""
            try await app.test(.POST, "\(apiBasePath)/participant/studies/\(studyId)/enrollments", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody([String: String]())
                            }) { response in
                let enrollment = try response.content.decode(Components.Schemas.EnrollmentResponse.self)
                enrollmentId = enrollment.id
            }

            let presentation = try await ConsentRequestFixtures.presentation(on: app, enrollmentID: enrollmentId, token: token)
            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(enrollmentId)/consents", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeMultipartConsentBody(
                    commandID: UUID(),
                    enrollmentETag: presentation.enrollmentETag,
                    consentData: consentDataJSON(
                        toggles: ["agree_data_use": true],
                        givenName: "Jane",
                        familyName: "Doe"
                    ), presentation: presentation.presentation
                )
            }) { response in
                #expect(response.status == .created)

                let consent = try response.content.decode(Components.Schemas.ConsentRecordResponse.self)
                #expect(consent.enrollmentId == enrollmentId)
                #expect(consent.revision == 1)
                #expect(consent.userResponses.toggles?.additionalProperties["agree_data_use"] == true)
            }
        }
    }

    @Test
    func identicalConsentReturnsOriginalReceipt() async throws {
        let commandID = UUID()
        try await TestApp.withApp(token: .participant(subject: Self.participantSubject)) { app, token in
            let (studyId, _) = try await setUpPublishedStudy(on: app)
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.participantSubject)

            let enrollmentId = try await enroll(on: app, studyID: studyId, token: token)

            let presentation = try await ConsentRequestFixtures.presentation(on: app, enrollmentID: enrollmentId, token: token)
            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(enrollmentId)/consents", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeMultipartConsentBody(
                    commandID: commandID,
                    enrollmentETag: presentation.enrollmentETag,
                    consentData: consentDataJSON(),
                    presentation: presentation.presentation
                )
            }) { response in
                #expect(response.status == .created)
            }

            let original = try #require(try await EnrollmentConsent.query(on: app.db).first())

            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(enrollmentId)/consents", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeMultipartConsentBody(
                    commandID: commandID,
                    enrollmentETag: presentation.enrollmentETag,
                    consentData: consentDataJSON(),
                    presentation: presentation.presentation
                )
            }) { response in
                #expect(response.status == .created)
                let receipt = try response.content.decode(Components.Schemas.ConsentRecordResponse.self)
                #expect(receipt.id == original.id?.uuidString)
            }
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 1)
        }
    }

    @Test
    func listConsentsReturnsAll() async throws {
        try await TestApp.withApp(token: .participant(subject: Self.participantSubject)) { app, token in
            let (studyId, _) = try await setUpPublishedStudy(on: app)
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.participantSubject)

            var enrollmentId: String = ""
            try await app.test(.POST, "\(apiBasePath)/participant/studies/\(studyId)/enrollments", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeJSONBody([String: String]())
                            }) { response in
                let enrollment = try response.content.decode(Components.Schemas.EnrollmentResponse.self)
                enrollmentId = enrollment.id
            }

            let presentation = try await ConsentRequestFixtures.presentation(on: app, enrollmentID: enrollmentId, token: token)
            try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(enrollmentId)/consents", beforeRequest: { req in
                req.bearerAuth(token)
                try req.encodeMultipartConsentBody(
                    commandID: UUID(),
                    enrollmentETag: presentation.enrollmentETag,
                    consentData: consentDataJSON(),
                    presentation: presentation.presentation
                )
            }) { _ in }

            try await app.test(.GET, "\(apiBasePath)/participant/enrollments/\(enrollmentId)/consents", beforeRequest: { req in
                req.bearerAuth(token)
            }) { response in
                #expect(response.status == .ok)

                let consents = try response.content.decode([Components.Schemas.ConsentRecordResponse].self)
                #expect(consents.count == 1)
            }
        }
    }

    // MARK: - Helpers

    private func enroll(on app: Application, studyID: UUID, token: String?) async throws -> String {
        var result: String?
        try await app.test(.POST, "\(apiBasePath)/participant/studies/\(studyID)/enrollments", beforeRequest: { request in
            request.bearerAuth(token)
            try request.encodeJSONBody([String: String]())
        }) { response in
            try #require(response.status == .created)
            result = try response.content.decode(Components.Schemas.EnrollmentResponse.self).id
        }
        return try #require(result)
    }

    @discardableResult
    private func setUpPublishedStudy(
        on app: Application,
        enrollmentCondition: EnrollmentConditions = .none
    ) async throws -> (UUID, Study) {
        let group = try await GroupFixtures.createGroup(on: app.db)
        let study = try await StudyFixtures.createStudy(
            on: app.db,
            groupId: try group.requireId(),
            enrollmentCondition: enrollmentCondition
        )
        let studyId = try study.requireId()
        try await PublishedStudyFixtures.createPublishedStudy(
            on: app.db,
            studyId: studyId,
            enrollmentCondition: enrollmentCondition,
            consentSnapshot: .init([
                .enUS: """
                <toggle id="agree_data_use" expected-value="true">I agree to data use.</toggle>
                <signature id="primary" />
                """
            ])
        )
        return (studyId, study)
    }

    private func consentDataJSON(
        toggles: [String: Bool] = ["agree_data_use": true],
        selects: [String: String] = [:],
        givenName: String = "Jane",
        familyName: String = "Doe"
    ) -> [String: Any] {
        [
            "toggles": toggles,
            "selects": selects,
            "signatures": [
                "primary": [
                    "name": ["givenName": givenName, "familyName": familyName],
                    "signature": "synthetic-signature-evidence",
                    "size": [120, 40]
                ] as [String: Any]
            ] as [String: Any]
        ] as [String: Any]
    }
}
