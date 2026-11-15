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
import TroveAPIClient
import TroveAPIServer
@testable import TroveServer


struct EnrollmentEndTests {
    @Test
    func joiningAfterPublishedCloseRollsBackEnrollment() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let existing = try #require(try await Study.find(fixture.studyIDs[0], on: app.db))
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: existing.$group.id)
            let id = try study.requireID()
            let period = EnrollmentPeriod(calendar: .gregorian, timeZone: "UTC", end: Date(timeIntervalSince1970: 1_000))
            try await PublishedStudyFixtures.createPublishedStudy(on: app.db, studyId: id, enrollmentPeriod: period)
            let count = try await Enrollment.query(on: app.db).count()
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                await #expect {
                    try await app.grove[ParticipantEnrollmentService.self].enroll(studyId: id, invitationCode: nil)
                } throws: { ($0 as? ServerError)?.status.code == 409 }
            }
            #expect(try await Enrollment.query(on: app.db).count() == count)
            #expect(try await Enrollment.query(on: app.db).filter(\.$study.$id == id).count() == 0)
        }
    }

    @Test
    func acceptanceInstantCannotCrossEnrollmentEndDuringTargetValidation() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app, consentCount: 1)
            let record = try #require(try await EnrollmentConsent.find(fixture.consentIDs[0], on: app.db))
            let publication = try #require(try await PublishedStudy.find(record.presentationProof.presentationID, on: app.db))
            let originalTime = record.createdAt
            let originalScope = record.collectionScope
            let end = try TroveDateTranscoder().decode("2027-01-01T00:00:00.123456Z")
            for instant in [end, end.addingTimeInterval(1)] {
                #expect(throws: ServerError.self) {
                    try record.resolveCollectionScope(from: publication, before: end, at: instant)
                }
                #expect(record.createdAt == originalTime && record.collectionScope == originalScope)
            }
            let before = end.addingTimeInterval(-1)
            try record.resolveCollectionScope(from: publication, before: end, at: before)
            #expect(record.createdAt == before)
            let retained = try #require(try await EnrollmentConsent.find(record.requireID(), on: app.db))
            #expect(retained.createdAt == originalTime && retained.collectionScope == originalScope)
        }
    }

    @Test
    func enrollmentResolvesPublishedPeriodOnceAndLaterAdoptionDoesNotRenewIt() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let existing = try #require(try await Study.find(fixture.studyIDs[0], on: app.db))
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: existing.$group.id)
            let id = try study.requireID()
            let period = EnrollmentPeriod(calendar: .gregorian, timeZone: "America/Los_Angeles", duration: .init(month: 6))
            try await PublishedStudyFixtures.createPublishedStudy(on: app.db, studyId: id, enrollmentPeriod: period)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let enrollment = try await app.grove[ParticipantEnrollmentService.self].enroll(studyId: id, invitationCode: nil)
                let joined = try #require(enrollment.createdAt)
                let end = try #require(enrollment.endsAt)
                #expect(end == (try period.resolve(at: joined)))
                let stored = try #require(try await Enrollment.find(enrollment.requireID(), on: app.db))
                #expect(abs(try #require(stored.endsAt).timeIntervalSince(end)) < 0.000001)
                try await PublishedStudyFixtures.createPublishedStudy(on: app.db, studyId: id, revision: 2)
                _ = try await ClinicalEventStoreTests.acceptConsent(enrollmentID: enrollment.requireID(), on: app, revision: 2)
                let adopted = try #require(try await Enrollment.find(enrollment.requireID(), on: app.db))
                #expect(adopted.endsAt == stored.endsAt)
                let plan = try await app.grove[ConsentService.self].collectionPlan(enrollmentID: enrollment.requireID())
                #expect(plan.endsAt == stored.endsAt && plan.windows.last?.end == stored.endsAt)
                #expect(try Components.Schemas.EnrollmentResponse(adopted).endsAt == stored.endsAt)
            }
        }
    }

    @Test
    func staleReviewCannotBeAcceptedAfterEndButCommittedConsentReceiptStillReplays() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app, consentCount: 1)
            let original = try #require(try await EnrollmentConsent.find(fixture.consentIDs[0], on: app.db))
            try await PublishedStudyFixtures.createNextClinicalRevision(on: app.db, studyId: fixture.studyIDs[0])
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let service = app.grove[ConsentService.self]
                let (review, version) = try await service.getPresentation(enrollmentId: fixture.enrollmentIDs[0], locale: "en-US", revision: 2)
                let enrollment = try #require(try await Enrollment.find(fixture.enrollmentIDs[0], on: app.db))
                enrollment.endsAt = Date()
                try await enrollment.save(on: app.db)
                await #expect {
                    try await service.createConsent(
                        enrollmentId: fixture.enrollmentIDs[0],
                        commandID: UUID(),
                        expectedEnrollmentVersion: version,
                        reviewedRevision: review.revision,
                        presentationProof: .init(presentationID: review.presentationID, locale: review.locale, digest: review.digest),
                        userResponses: .init(toggles: ["agree": true]),
                        pdfData: Data("%PDF-1.4 Synthetic consent evidence".utf8)
                    )
                } throws: { ($0 as? ServerError)?.status.code == 409 }
                let replay = try await service.createConsent(
                    enrollmentId: fixture.enrollmentIDs[0],
                    commandID: original.commandID,
                    expectedEnrollmentVersion: original.expectedEnrollmentVersion,
                    reviewedRevision: original.revision,
                    presentationProof: original.presentationProof,
                    userResponses: original.userResponses,
                    pdfData: Data("%PDF-1.4 Synthetic consent evidence".utf8)
                )
                #expect(replay.id == original.id)
                #expect(try await EnrollmentConsent.query(on: app.db).count() == 1)
            }
        }
    }

    @Test
    func endedEnrollmentStillAdmitsQueuedPreEndMeasurementsButRejectsBoundaryAndNewConsent() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let consent = try #require(try await EnrollmentConsent.find(fixture.consentIDs[0], on: app.db))
            let acceptedAt = try #require(consent.createdAt)
            let enrollment = try #require(try await Enrollment.find(fixture.enrollmentIDs[0], on: app.db))
            enrollment.endsAt = Date()
            try await enrollment.save(on: app.db)
            let stored = try #require(try await Enrollment.find(fixture.enrollmentIDs[0], on: app.db))
            let end = try #require(stored.endsAt)
            try #require(acceptedAt < end)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let service = app.grove[ConsentService.self]
                let plan = try await service.collectionPlan(enrollmentID: fixture.enrollmentIDs[0])
                let snapshot = try ParticipantCollectionSnapshot(plans: [plan], enrollmentIDs: [fixture.enrollmentIDs[0]])
                #expect(try snapshot.active().permitsHeartRateAcquisition == false)
                #expect(plan.windows[0].requirements[0].end == end)
                let before = ClinicalEventStoreTests.event(source: fixture.source, sequence: 1, effectiveAt: acceptedAt)
                let store = ClinicalEventStore(database: app.db)
                _ = try await store.accept(
                    before, sourceID: fixture.source.id, targets: [fixture.targets[0]], installation: fixture.installation
                )
                let boundary = ClinicalEventStoreTests.event(source: fixture.source, sequence: 2, effectiveAt: end)
                await #expect {
                    try await store.accept(boundary, sourceID: fixture.source.id, targets: [fixture.targets[0]], installation: fixture.installation)
                } throws: { ($0 as? ServerError)?.status.code == 403 }
                await #expect {
                    try await service.getPresentation(enrollmentId: fixture.enrollmentIDs[0], locale: "en-US")
                } throws: { ($0 as? ServerError)?.status.code == 409 }
                try await ClinicalEventStoreTests.expectRows(events: 1, nodes: 2, facts: 1, grants: 1, on: app.db)
            }
        }
    }
}
