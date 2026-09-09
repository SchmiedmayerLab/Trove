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


private actor ConsentCommandStorage: ObjectStorageProvider {
    private var objects: [String: Data] = [:]
    private(set) var uploads = 0
    private let pauseFirstUpload: Bool
    private let staged = AsyncStream<Void>.makeStream()
    private let released = AsyncStream<Void>.makeStream()

    init(pauseFirstUpload: Bool = false) {
        self.pauseFirstUpload = pauseFirstUpload
    }

    func upload(data: Data, key: String, contentType: String) async throws {
        uploads += 1
        objects[key] = data
        if pauseFirstUpload, uploads == 1 {
            staged.continuation.yield(())
            staged.continuation.finish()
            for await _ in released.stream { break }
            try Task.checkCancellation()
        }
    }

    func waitUntilStaged() async throws {
        for await _ in staged.stream { break }
        try Task.checkCancellation()
    }

    func releaseFirstUpload() {
        released.continuation.yield(())
        released.continuation.finish()
    }

    func download(key: String, maximumBytes: Int = 50 * 1024 * 1024) throws -> Data {
        guard let data = objects[key] else {
            throw ServerError.notFound("Synthetic consent evidence not found")
        }
        return data
    }

    func ensureBucketExists() {}
    func delete(key: String) { objects.removeValue(forKey: key) }
    func shutdown() {}
}


struct ConsentCommandIntegrationTests {
    private struct Context {
        let enrollmentID: UUID
        let presentation: Components.Schemas.ConsentPresentationResponse

        var path: String { "\(apiBasePath)/participant/enrollments/\(enrollmentID)" }

        func encode(_ request: inout TestingHTTPRequest, commandID: UUID, pdf: Data = Data("%PDF-1.4 test".utf8)) throws {
            try request.encodeMultipartConsentBody(
                commandID: commandID,
                enrollmentETag: presentation.enrollmentETag,
                consentData: ["toggles": ["agree": true], "selects": [:], "signatures": [:]],
                presentation: presentation.presentation,
                pdfData: pdf,
                reviewedRevision: presentation.revision
            )
        }

        func submit(on app: Application, token: String?, commandID: UUID) async throws -> Components.Schemas.ConsentRecordResponse {
            var receipt: Components.Schemas.ConsentRecordResponse?
            try await app.test(.POST, "\(path)/consents", beforeRequest: { request in
                request.bearerAuth(token)
                try encode(&request, commandID: commandID)
            }) { response in
                try #require(response.status == .created)
                receipt = try response.content.decode(Components.Schemas.ConsentRecordResponse.self)
            }
            return try #require(receipt)
        }
    }

    private static let subject = "consent-command-participant"

    private static func fixture(on app: Application, token: String?) async throws -> Context {
        let group = try await GroupFixtures.createGroup(on: app.db)
        let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
        let participant = try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: subject)
        try await PublishedStudyFixtures.createPublishedStudy(
            on: app.db,
            studyId: study.requireId(),
            revision: 1,
            consentSnapshot: .init([.enUS: PublishedStudyFixtures.requiredConsentMarkdown])
        )
        let enrollment = Enrollment(participantId: try participant.requireId(), studyId: try study.requireId(), currentRevision: 1)
        try await enrollment.save(on: app.db)
        let id = try enrollment.requireId()
        let presentation = try await ConsentRequestFixtures.presentation(on: app, enrollmentID: id.uuidString, token: token)
        #expect(presentation.enrollmentStateVersion == enrollment.stateVersion)
        return Context(enrollmentID: id, presentation: presentation)
    }

    @Test
    func exactRetryAfterWithdrawalReturnsOriginalAcceptanceWithoutMutation() async throws {
        let storage = ConsentCommandStorage()
        let commandID = UUID()
        try await TestApp.withApp(token: .participant(subject: Self.subject), storageProvider: storage) { app, token in
            let context = try await Self.fixture(on: app, token: token)
            var receipt: Components.Schemas.ConsentRecordResponse?
            try await app.test(.POST, "\(context.path)/consents", beforeRequest: { request in
                request.bearerAuth(token)
                try context.encode(&request, commandID: commandID)
            }) { response in
                try #require(response.status == .created)
                receipt = try response.content.decode(Components.Schemas.ConsentRecordResponse.self)
            }
            let accepted = try #require(receipt)
            #expect(accepted.acceptedEnrollmentVersion == context.presentation.enrollmentStateVersion + 1)
            try await app.test(.POST, "\(context.path)/withdraw", beforeRequest: { $0.bearerAuth(token) }) { response in
                try #require(response.status == .ok)
            }
            let withdrawn = try #require(try await Enrollment.find(context.enrollmentID, on: app.db))
            try #require(withdrawn.withdrawnAt != nil)
            try await app.test(.POST, "\(context.path)/consents", beforeRequest: { request in
                request.bearerAuth(token)
                try context.encode(&request, commandID: commandID)
            }) { response in
                try #require(response.status == .created)
                let replay = try response.content.decode(Components.Schemas.ConsentRecordResponse.self)
                #expect(replay.id == accepted.id)
                #expect(replay.acceptedEnrollmentVersion == accepted.acceptedEnrollmentVersion)
            }
            let retained = try #require(try await Enrollment.find(context.enrollmentID, on: app.db))
            #expect(retained.stateVersion == withdrawn.stateVersion)
            #expect(retained.withdrawnAt == withdrawn.withdrawnAt)
            #expect(retained.updatedAt == withdrawn.updatedAt)
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 1)
            #expect(await storage.uploads == 1)
        }
    }

    @Test
    func staleVersionCannotUploadOrAcceptEvidence() async throws {
        let storage = ConsentCommandStorage()
        try await TestApp.withApp(token: .participant(subject: Self.subject), storageProvider: storage) { app, token in
            let context = try await Self.fixture(on: app, token: token)
            let enrollment = try #require(try await Enrollment.find(context.enrollmentID, on: app.db))
            enrollment.stateVersion += 1
            try await enrollment.save(on: app.db)
            // Compare persisted state on both sides: PostgreSQL stores microsecond timestamps,
            // which need not equal the in-memory Date assigned by Fluent on every platform.
            let beforeRequest = try #require(try await Enrollment.find(context.enrollmentID, on: app.db))
            try await app.test(.POST, "\(context.path)/consents", beforeRequest: { request in
                request.bearerAuth(token)
                try context.encode(&request, commandID: UUID())
            }) { response in
                #expect(response.status == .preconditionFailed)
            }
            let retained = try #require(try await Enrollment.find(context.enrollmentID, on: app.db))
            #expect(retained.stateVersion == beforeRequest.stateVersion)
            #expect(retained.updatedAt == beforeRequest.updatedAt)
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 0)
            #expect(await storage.uploads == 0)
        }
    }

    @Test(arguments: ["changed-body", "new-command", "changed-version"])
    func conflictingCommandsDoNotReplaceEvidence(change: String) async throws {
        let storage = ConsentCommandStorage()
        let commandID = UUID()
        try await TestApp.withApp(token: .participant(subject: Self.subject), storageProvider: storage) { app, token in
            let context = try await Self.fixture(on: app, token: token)
            try await app.test(.POST, "\(context.path)/consents", beforeRequest: { request in
                request.bearerAuth(token)
                try context.encode(&request, commandID: commandID)
            }) { response in
                try #require(response.status == .created)
            }
            let accepted = try #require(try await EnrollmentConsent.query(on: app.db).first())
            let enrollment = try #require(try await Enrollment.find(context.enrollmentID, on: app.db))
            let latest = try await ConsentRequestFixtures.presentation(on: app, enrollmentID: context.enrollmentID.uuidString, token: token)
            try await app.test(.POST, "\(context.path)/consents", beforeRequest: { request in
                request.bearerAuth(token)
                try context.encode(
                    &request,
                    commandID: change == "new-command" ? UUID() : commandID,
                    pdf: Data((change == "changed-body" ? "%PDF changed" : "%PDF-1.4 test").utf8)
                )
                if change != "changed-body" {
                    request.headers.replaceOrAdd(name: "If-Match", value: latest.enrollmentETag)
                }
            }) { response in
                #expect(response.status == .conflict)
            }
            let retained = try #require(try await EnrollmentConsent.find(accepted.requireId(), on: app.db))
            #expect(retained.evidenceKey == accepted.evidenceKey)
            #expect(retained.evidenceDigest == accepted.evidenceDigest)
            #expect(try await Enrollment.find(context.enrollmentID, on: app.db)?.stateVersion == enrollment.stateVersion)
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 1)
            #expect(await storage.uploads == 1)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func overlappingIdenticalCommandsReturnTheWinningReceipt() async throws {
        let storage = ConsentCommandStorage(pauseFirstUpload: true)
        let commandID = UUID()
        try await TestApp.withApp(token: .participant(subject: Self.subject), storageProvider: storage) { app, token in
            let context = try await Self.fixture(on: app, token: token)
            let receipts = try await withThrowingTaskGroup(of: Components.Schemas.ConsentRecordResponse.self) { group in
                group.addTask { try await context.submit(on: app, token: token, commandID: commandID) }
                group.addTask {
                    do {
                        try await storage.waitUntilStaged()
                        let receipt = try await context.submit(on: app, token: token, commandID: commandID)
                        await storage.releaseFirstUpload()
                        return receipt
                    } catch {
                        await storage.releaseFirstUpload()
                        throw error
                    }
                }
                var results: [Components.Schemas.ConsentRecordResponse] = []
                for try await receipt in group { results.append(receipt) }
                return results
            }
            try #require(receipts.count == 2)
            #expect(receipts[0].id == receipts[1].id)
            #expect(receipts.allSatisfy { $0.acceptedEnrollmentVersion == context.presentation.enrollmentStateVersion + 1 })
            #expect(try await Enrollment.find(context.enrollmentID, on: app.db)?.stateVersion == context.presentation.enrollmentStateVersion + 1)
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 1)
            #expect(await storage.uploads == 2)
            let sql = try #require(app.db as? any SQLDatabase)
            let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM audit_events WHERE action = 'consent.recorded'").first())
            #expect(try row.decode(column: "count", as: Int.self) == 1)
        }
    }

    @Test(arguments: ["Idempotency-Key", "If-Match", "both"])
    func missingCommandHeadersCannotUploadEvidence(header: String) async throws {
        let storage = ConsentCommandStorage()
        try await TestApp.withApp(token: .participant(subject: Self.subject), storageProvider: storage) { app, token in
            let context = try await Self.fixture(on: app, token: token)
            try await app.test(.POST, "\(context.path)/consents", beforeRequest: { request in
                request.bearerAuth(token)
                try context.encode(&request, commandID: UUID())
                for name in header == "both" ? ["Idempotency-Key", "If-Match"] : [header] {
                    request.headers.remove(name: name)
                }
            }) { response in
                #expect(response.status == .badRequest)
            }
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 0)
            #expect(await storage.uploads == 0)
        }
    }

    @Test(arguments: ["*", "unquoted", "W/\"enrollment-invalid-v1\"", "\"a\", \"b\""])
    func malformedVersionTagsCannotUploadEvidence(tag: String) async throws {
        let storage = ConsentCommandStorage()
        try await TestApp.withApp(token: .participant(subject: Self.subject), storageProvider: storage) { app, token in
            let context = try await Self.fixture(on: app, token: token)
            try await app.test(.POST, "\(context.path)/consents", beforeRequest: { request in
                request.bearerAuth(token)
                try context.encode(&request, commandID: UUID())
                request.headers.replaceOrAdd(name: "If-Match", value: tag)
            }) { response in
                #expect(response.status == .badRequest)
            }
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 0)
            #expect(await storage.uploads == 0)
        }
    }
}


extension ConsentCommandIntegrationTests {
    @Test
    func auditFailurePreventsAcceptedReplayDisclosureWithoutMutation() async throws {
        let storage = ConsentCommandStorage()
        let commandID = UUID()
        try await TestApp.withApp(token: .participant(subject: Self.subject), storageProvider: storage) { app, token in
            let context = try await Self.fixture(on: app, token: token)
            let receipt = try await context.submit(on: app, token: token, commandID: commandID)
            let accepted = try #require(try await EnrollmentConsent.query(on: app.db).first())
            let enrollment = try #require(try await Enrollment.find(context.enrollmentID, on: app.db))
            try await app.db.schema("audit_events").delete()
            try await app.test(.POST, "\(context.path)/consents", beforeRequest: { request in
                request.bearerAuth(token)
                try context.encode(&request, commandID: commandID)
            }) { response in
                #expect(response.status == .internalServerError)
                #expect(!response.body.string.contains(receipt.id))
                #expect(!response.body.string.contains("userResponses"))
                #expect(!response.body.string.contains("signatures"))
                #expect(!response.body.string.contains("acceptedEnrollmentVersion"))
            }
            let retained = try #require(try await EnrollmentConsent.find(accepted.requireId(), on: app.db))
            #expect(retained.evidenceKey == accepted.evidenceKey)
            #expect(retained.evidenceDigest == accepted.evidenceDigest)
            #expect(retained.acceptedEnrollmentVersion == accepted.acceptedEnrollmentVersion)
            #expect(retained.updatedAt == accepted.updatedAt)
            let unchanged = try #require(try await Enrollment.find(context.enrollmentID, on: app.db))
            #expect(unchanged.stateVersion == enrollment.stateVersion)
            #expect(unchanged.updatedAt == enrollment.updatedAt)
            #expect(try await EnrollmentConsent.query(on: app.db).count() == 1)
            #expect(await storage.uploads == 1)
        }
    }
}
