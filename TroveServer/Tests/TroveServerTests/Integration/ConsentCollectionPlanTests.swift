//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import SQLKit
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


struct ConsentCollectionPlanTests {
    @Test
    func wireCollectionWindowsRetainTheirStoredPrecision() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let stored = try #require(try await EnrollmentConsent.find(fixture.consentIDs[0], on: app.db))
            let plan = try await Self.read(fixture.enrollmentIDs[0], on: app, token: token)
            let window = try #require(plan.windows.first)
            #expect(window.start == stored.createdAt)
        }
    }

    @Test(arguments: 0..<4)
    func acceptedReceiptUsesTheStoredTimelineInstant(_: Int) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app, consentCount: 1)
            let accepted = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await ClinicalEventStoreTests.acceptConsent(enrollmentID: fixture.enrollmentIDs[1], on: app)
            }
            let stored = try #require(try await EnrollmentConsent.find(accepted.requireID(), on: app.db))
            #expect(accepted.createdAt == stored.createdAt)
            #expect(accepted.updatedAt == stored.updatedAt)
            #expect(accepted.acceptedEnrollmentVersion == stored.acceptedEnrollmentVersion)
        }
    }

    @Test
    func ownerReceivesOnlyCollectionMetadataAfterAudit() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let plan = try await Self.read(fixture.enrollmentIDs[0], on: app, token: token)
            #expect(plan.enrollmentId == fixture.enrollmentIDs[0].uuidString.lowercased())
            #expect(plan.stateVersion == 2)
            let window = try #require(plan.windows.first)
            #expect(plan.windows.count == 1)
            #expect(window.consentId == fixture.consentIDs[0].uuidString.lowercased())
            #expect(window.revision == 1 && window.end == nil && window.start <= plan.asOf)
            #expect(window.requirements == [.init(profile: CollectionRequirement.supportedProfile, sourceKind: .participantApp)])
            let sql = try Self.sql(app)
            let audit = try #require(try await sql.raw("""
                SELECT actor_subject, study_id, group_id, target_id, outcome FROM audit_events WHERE action = 'collection.plan.disclosure'
                """)
                .first())
            #expect(try audit.decode(column: "actor_subject", as: String.self) == "test-participant")
            #expect(try audit.decode(column: "study_id", as: UUID.self) == fixture.studyIDs[0])
            let study = try #require(try await Study.find(fixture.studyIDs[0], on: app.db))
            #expect(try audit.decode(column: "group_id", as: UUID.self) == study.$group.id)
            #expect(try audit.decode(column: "target_id", as: UUID.self) == fixture.enrollmentIDs[0])
            #expect(try audit.decode(column: "outcome", as: String.self) == "disclosure_intent")
        }
    }

    @Test
    func publicationDoesNotChangeThePlanButReviewedAdoptionClosesItsOldWindow() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let before = try await Self.read(fixture.enrollmentIDs[0], on: app, token: token)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.researcher) {
                _ = try await app.grove[PublishedStudyService.self].publish(studyId: fixture.studyIDs[0])
            }
            let published = try await Self.read(fixture.enrollmentIDs[0], on: app, token: token)
            #expect(published.windows == before.windows && published.stateVersion == before.stateVersion)
            let accepted = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await ClinicalEventStoreTests.acceptConsent(enrollmentID: fixture.enrollmentIDs[0], on: app, revision: 2)
            }
            let adopted = try await Self.read(fixture.enrollmentIDs[0], on: app, token: token)
            try #require(adopted.windows.count == 2)
            #expect(adopted.stateVersion == 3)
            #expect(adopted.windows[0].consentId == before.windows[0].consentId)
            #expect(adopted.windows[0].end == adopted.windows[1].start)
            #expect(adopted.windows[1].consentId == accepted.id?.uuidString.lowercased())
            #expect(adopted.windows[1].revision == 2 && adopted.windows[1].end == nil)
        }
    }

    @Test
    func withdrawalRemovesOnlyItsEnrollmentsWindows() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let other = try await Self.read(fixture.enrollmentIDs[1], on: app, token: token)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: fixture.enrollmentIDs[0])
            }
            let withdrawn = try await Self.read(fixture.enrollmentIDs[0], on: app, token: token)
            #expect(withdrawn.windows.isEmpty && withdrawn.stateVersion == 3)
            #expect(try await Self.read(fixture.enrollmentIDs[1], on: app, token: token).windows == other.windows)
        }
    }

    @Test
    func enrollmentWithoutAcceptedConsentCannotCollect() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app, consentCount: 1)
            let plan = try await Self.read(fixture.enrollmentIDs[1], on: app, token: token)
            #expect(plan.windows.isEmpty && plan.stateVersion == 1)
        }
    }

    @Test
    func emptyPublishedPolicyIsNotAnUnknownPolicyOrCollectionPermission() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app, secondPolicy: false)
            let plan = try await Self.read(fixture.enrollmentIDs[1], on: app, token: token)
            #expect(plan.windows.count == 1)
            #expect(try #require(plan.windows.first).requirements.isEmpty)
        }
    }

    @Test(arguments: [(TestApp.Token.none, 401), (.researcher(), 403), (.participant(subject: "other-participant"), 404)])
    func onlyTheAuthenticatedOwnerCanRead(identity: TestApp.Token, status: Int) async throws {
        try await TestApp.withApp(token: identity) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: "other-participant")
            try await app.test(.GET, Self.path(fixture.enrollmentIDs[0]), beforeRequest: { $0.bearerAuth(token) }) { response in
                #expect(Int(response.status.code) == status)
                #expect(!response.body.string.contains(fixture.consentIDs[0].uuidString.lowercased()))
            }
            let sql = try Self.sql(app)
            let row = try #require(try await sql.raw("SELECT count(*) AS count FROM audit_events WHERE action = 'collection.plan.disclosure'")
                .first())
            #expect(try row.decode(column: "count", as: Int.self) == 0)
        }
    }

    @Test
    func auditFailurePreventsDisclosure() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await app.db.schema("audit_events").delete()
            try await app.test(.GET, Self.path(fixture.enrollmentIDs[0]), beforeRequest: { $0.bearerAuth(token) }) { response in
                #expect(response.status == .internalServerError)
                #expect(!response.body.string.contains(fixture.consentIDs[0].uuidString.lowercased()))
            }
        }
    }
    @Test
    func unknownRetainedPolicyNeverProducesAPartialPlan() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let participant = try await ParticipantFixtures.createParticipant(on: app.db)
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireID())
            let publication = try await PublishedStudyFixtures.createPublishedStudy(on: app.db, studyId: study.requireID(), save: false)
            var policy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(publication.collectionPolicy)) as? [String: Any])
            policy["contractVersion"] = "unsupported"
            publication.collectionPolicy = try JSONDecoder().decode(
                PublishedCollectionPolicy.self, from: JSONSerialization.data(withJSONObject: policy)
            )
            try await publication.save(on: app.db)
            let enrollment = Enrollment(participantId: try participant.requireID(), studyId: try study.requireID(), currentRevision: 1)
            try await enrollment.save(on: app.db)
            _ = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await ClinicalEventStoreTests.acceptConsent(enrollmentID: enrollment.requireID(), on: app)
            }
            try await app.test(.GET, Self.path(enrollment.requireID()), beforeRequest: { $0.bearerAuth(token) }) { response in
                #expect(response.status == .internalServerError)
                #expect(!response.body.string.contains("windows"))
            }
        }
    }

    @Test
    func concurrentWithdrawalCannotMixOldWindowsWithNewState() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            async let read = Self.read(fixture.enrollmentIDs[0], on: app, token: token)
            async let withdrawal = AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: fixture.enrollmentIDs[0])
            }
            let (plan, _) = try await (read, withdrawal)
            #expect(["2:1", "3:0"].contains("\(plan.stateVersion):\(plan.windows.count)"))
            #expect(try await Self.read(fixture.enrollmentIDs[0], on: app, token: token).windows.isEmpty)
        }
    }
}


extension ConsentCollectionPlanTests {
    private static func path(_ id: UUID) -> String { "\(apiBasePath)/participant/enrollments/\(id)/collection-plan" }

    private static func sql(_ app: Application) throws -> any SQLDatabase { try #require(app.db as? any SQLDatabase) }

    private static func read(_ id: UUID, on app: Application, token: String?) async throws -> Components.Schemas.ParticipantCollectionPlan {
        var plan: Components.Schemas.ParticipantCollectionPlan?
        try await app.test(.GET, path(id), beforeRequest: { $0.bearerAuth(token) }) { response in
            try #require(response.status == .ok)
            #expect(response.headers.first(name: "Cache-Control") == "no-store")
            let json = try #require(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
            #expect(Set(json.keys) == ["enrollmentId", "stateVersion", "asOf", "windows"])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { value in
                try TroveDateTranscoder().decode(value.singleValueContainer().decode(String.self))
            }
            plan = try decoder.decode(Components.Schemas.ParticipantCollectionPlan.self, from: Data(response.body.readableBytesView))
            #expect(!response.body.string.contains("userResponses") && !response.body.string.contains("signatures"))
        }
        return try #require(plan)
    }
}
