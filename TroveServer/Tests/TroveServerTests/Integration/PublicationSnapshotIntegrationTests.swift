//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Fluent
import Foundation
import GroveLocalization
import JWTKit
import SQLKit
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting
import ZIPFoundation


private actor PublicationStorage: ObjectStorageProvider {
    private var objects: [String: Data] = [:]
    private var nextUpload: (@Sendable () async throws -> Void)?
    private(set) var uploads: [String] = []
    private(set) var downloads: [String] = []

    func afterNextUpload(_ action: @escaping @Sendable () async throws -> Void) {
        nextUpload = action
    }

    func upload(data: Data, key: String, contentType: String) async throws {
        objects[key] = data
        uploads.append(key)
        let action = nextUpload
        nextUpload = nil
        try await action?()
    }

    func download(key: String, maximumBytes: Int = 50 * 1024 * 1024) throws -> Data {
        downloads.append(key)
        guard let data = objects[key] else { throw ServerError.notFound("Synthetic object not found") }
        return data
    }

    func ensureBucketExists() {}
    func delete(key: String) { objects.removeValue(forKey: key) }
    func shutdown() {}
}


struct PublicationSnapshotIntegrationTests {
    @Test
    func terminalRevisionCannotOverflowOrUploadAnotherArchive() async throws {
        let storage = PublicationStorage()
        try await TestApp.withApp(storageProvider: storage) { app, token in
            let study = try await Self.study(on: app)
            let studyID = try study.requireId()
            try await PublishedStudyFixtures.createPublishedStudy(on: app.db, studyId: studyID, revision: Int.max)
            try await Self.publish(studyID, app: app, token: token, expected: .conflict)
            #expect(try await PublishedStudy.query(on: app.db).count() == 1)
            #expect(await storage.uploads.isEmpty)
        }
    }

    @Test
    func deletionDuringUploadCannotLeaveAnAcceptedPublication() async throws {
        let storage = PublicationStorage()
        try await TestApp.withApp(storageProvider: storage) { app, token in
            let study = try await Self.study(on: app)
            let studyID = try study.requireId()
            await storage.afterNextUpload {
                try await app.test(.DELETE, "\(apiBasePath)/studies/\(studyID)", beforeRequest: { request in
                    request.bearerAuth(token)
                }) { response in
                    #expect(response.status == .noContent)
                }
            }
            try await Self.publish(studyID, app: app, token: token, expected: .conflict)
            #expect(try await Study.find(studyID, on: app.db) == nil)
            #expect(try await PublishedStudy.query(on: app.db).count() == 0)
            #expect(try await StoredArtifact.query(on: app.db).filter(\.$state == .retained).count() == 0)
            let store = ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self])
            #expect(try await store.cleanup(now: Date().addingTimeInterval(7200)).deleted == 1)
        }
    }

    @Test
    func auditFailureCannotActivatePublication() async throws {
        let storage = PublicationStorage()
        try await TestApp.withApp(storageProvider: storage) { app, token in
            let study = try await Self.study(on: app)
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("DROP TABLE audit_events").run()
            try await Self.publish(study.requireId(), app: app, token: token, expected: .internalServerError)
            #expect(try await PublishedStudy.query(on: app.db).count() == 0)
            #expect(await storage.uploads.count == 1)
            let verificationReads = await storage.downloads
            #expect(verificationReads.count == 1)
            let participantToken = try await Self.enroll(on: app, studyID: study.requireId())
            try await Self.download(study.requireId(), app: app, token: participantToken) { response in
                #expect(response.status == .notFound)
            }
            #expect(await storage.downloads == verificationReads)
        }
    }

    @Test
    func malformedConsentCannotBePublished() async throws {
        let storage = PublicationStorage()
        try await TestApp.withApp(storageProvider: storage) { app, token in
            let study = try await Self.study(on: app)
            study.consent[.enUS] = ConsentContent(title: "Consent", content: "<toggle id=\"agree\" expected-value=\"maybe\">Agree</toggle>")
            try await study.save(on: app.db)
            try await Self.publish(study.requireId(), app: app, token: token, expected: .badRequest)
            #expect(try await PublishedStudy.query(on: app.db).count() == 0)
            #expect(await storage.uploads.isEmpty)
        }
    }

    @Test
    func publicationRetainsConsentAndArchiveAfterDraftEdit() async throws {
        let storage = PublicationStorage()
        try await TestApp.withApp(storageProvider: storage) { app, token in
            let study = try await Self.study(on: app)
            let studyID = try study.requireId()
            try await Self.publish(studyID, app: app, token: token, expected: .created)
            let published = try #require(try await PublishedStudy.query(on: app.db).first())
            let key = published.bundleKey
            let original = try await storage.download(key: key)
            #expect(key.contains("/publications/"))
            #expect(published.bundleDigest == Self.digest(original))
            let markdown = try #require(published.consentSnapshot[.enUS])
            #expect(markdown == "---\ntitle: Consent\nversion: 1.0.0\n---\nOriginal reviewed text")
            let archive = try Archive(data: original, accessMode: .read)
            let consentEntry = try #require(archive.first { $0.path.hasSuffix("/Consent+en-US.md") })
            var archivedMarkdown = Data()
            _ = try archive.extract(consentEntry) { archivedMarkdown.append($0) }
            #expect(archivedMarkdown == Data(markdown.utf8))
            let presentation = try ConsentPresentation(published: published, locale: "en-US")
            #expect(presentation.digest == Self.digest(archivedMarkdown))

            study.consent[.enUS] = ConsentContent(title: "Changed", content: "Unpublished text")
            try await study.save(on: app.db)
            let retained = try #require(try await PublishedStudy.find(published.requireId(), on: app.db))
            #expect(retained.consentSnapshot[.enUS] == markdown)
            let participantToken = try await Self.enroll(on: app, studyID: studyID)
            try await Self.download(studyID, app: app, token: participantToken) { response in
                #expect(response.status == .ok)
                #expect(Data(buffer: response.body) == original)
            }
            #expect(try await PublishedStudy.find(published.requireId(), on: app.db)?.bundleKey == key)
        }
    }

    @Test
    func competingPublicationCannotOverwriteAcceptedArchive() async throws {
        let storage = PublicationStorage()
        try await TestApp.withApp(storageProvider: storage) { app, token in
            let study = try await Self.study(on: app)
            let studyID = try study.requireId()
            // Pause the first request after upload. A second publisher wins revision 1
            // before the first inserts its receipt: deterministic collision, no sleeps.
            await storage.afterNextUpload {
                study.consent[.enUS] = ConsentContent(title: "Second", content: "Winning publication")
                try await study.save(on: app.db)
                try await Self.publish(studyID, app: app, token: token, expected: .created)
            }
            try await Self.publish(studyID, app: app, token: token, expected: .conflict)
            #expect(try await PublishedStudy.query(on: app.db).count() == 1)
            let winner = try #require(try await PublishedStudy.query(on: app.db).first())
            let key = winner.bundleKey
            #expect(winner.consentSnapshot[.enUS] == "---\ntitle: Second\nversion: 1.0.0\n---\nWinning publication")
            let uploads = await storage.uploads
            #expect(uploads.count == 2)
            #expect(Set(uploads).count == 2)
            #expect(uploads.last == key)
            let acceptedBytes = try await storage.download(key: key)
            #expect(winner.bundleDigest == Self.digest(acceptedBytes))
            let participantToken = try await Self.enroll(on: app, studyID: studyID)
            try await Self.download(studyID, app: app, token: participantToken) { response in
                #expect(response.status == .ok)
                #expect(Data(buffer: response.body) == acceptedBytes)
            }
        }
    }

    @Test
    func failedStorageDoesNotPublishRevision() async throws {
        let storage = PublicationStorage()
        try await TestApp.withApp(storageProvider: storage) { app, token in
            let study = try await Self.study(on: app)
            await storage.afterNextUpload { throw ServerError.internalServerError("Synthetic storage interruption") }
            try await Self.publish(study.requireId(), app: app, token: token, expected: .internalServerError)
            #expect(try await PublishedStudy.query(on: app.db).count() == 0)
        }
    }

    @Test
    func corruptedPublishedArchiveIsNotDisclosed() async throws {
        let storage = PublicationStorage()
        try await TestApp.withApp(storageProvider: storage) { app, token in
            let study = try await Self.study(on: app)
            let studyID = try study.requireId()
            try await Self.publish(studyID, app: app, token: token, expected: .created)
            let published = try #require(try await PublishedStudy.query(on: app.db).first())
            let key = published.bundleKey
            try await storage.upload(data: Data("corrupted archive".utf8), key: key, contentType: "application/zip")
            let participantToken = try await Self.enroll(on: app, studyID: studyID)
            try await Self.download(studyID, app: app, token: participantToken) { response in
                #expect(response.status == .internalServerError)
                #expect(!response.body.string.contains("corrupted archive"))
            }
        }
    }

    @Test(arguments: ["bundle_key", "bundle_digest", "consent_snapshot", "artifact_id", "collection_policy"])
    func publishedArchiveRequiresCompleteEvidence(column: String) async throws {
        try await TestApp.withApp { app, token in
            let study = try await Self.study(on: app)
            let studyID = try study.requireId()
            try await Self.publish(studyID, app: app, token: token, expected: .created)
            let published = try #require(try await PublishedStudy.query(on: app.db).first())
            let candidate = try await PublishedStudyFixtures.createPublishedStudy(on: app.db, studyId: studyID, revision: 2, save: false)
            switch column {
            case "bundle_key": candidate.$bundleKey.value = nil
            case "bundle_digest": candidate.$bundleDigest.value = nil
            case "consent_snapshot": candidate.$consentSnapshot.value = nil
            case "collection_policy": candidate.$collectionPolicy.value = nil
            default: candidate.$artifactID.value = nil
            }
            await #expect {
                try await candidate.save(on: app.db)
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            let retained = try #require(try await PublishedStudy.find(published.requireId(), on: app.db))
            #expect(retained.bundleKey == published.bundleKey)
            #expect(retained.bundleDigest == published.bundleDigest)
            #expect(retained.artifactID == published.artifactID)
            let participantToken = try await Self.enroll(on: app, studyID: studyID)
            try await Self.download(studyID, app: app, token: participantToken) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test
    func unpublishedRevisionDoesNotReadOrphanedObject() async throws {
        let storage = PublicationStorage()
        try await TestApp.withApp(storageProvider: storage) { app, _ in
            let study = try await Self.study(on: app)
            let studyID = try study.requireId()
            try await storage.upload(data: Data("unaccepted".utf8), key: "studies/\(studyID)/1.zip", contentType: "application/zip")
            let participantToken = try await Self.enroll(on: app, studyID: studyID)
            try await Self.download(studyID, app: app, token: participantToken) { response in
                #expect(response.status == .notFound)
            }
            #expect(await storage.downloads.isEmpty)
        }
    }
}


extension PublicationSnapshotIntegrationTests {
    private static func study(on app: Application) async throws -> Study {
        let group = try await GroupFixtures.createGroup(on: app.db)
        let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
        study.consent[.enUS] = ConsentContent(title: "Consent", content: "Original reviewed text")
        try await study.save(on: app.db)
        return study
    }

    private static func publish(_ id: UUID, app: Application, token: String?, expected: HTTPStatus) async throws {
        try await app.test(.POST, "\(apiBasePath)/studies/\(id)/publish", beforeRequest: { $0.bearerAuth(token) }) {
            #expect($0.status == expected)
        }
    }

    private static func enroll(on app: Application, studyID: UUID) async throws -> String {
        let subject = "publication-participant"
        let participant = try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: subject)
        try await Enrollment(participantId: participant.requireId(), studyId: studyID, currentRevision: 1).save(on: app.db)
        let keys = JWTKeyCollection()
        await keys.add(hmac: HMACKey(from: TestApp.testSecret), digestAlgorithm: .sha256, kid: "test-key")
        return try await TestApp.signToken(keys: keys, subject: subject, roles: [TestApp.participantRole], groups: [])
    }

    private static func download(
        _ id: UUID,
        app: Application,
        token: String,
        verify: @escaping @Sendable (TestingHTTPResponse) async throws -> Void
    ) async throws {
        try await app.test(.GET, "\(apiBasePath)/participant/studies/\(id)/1/bundle", beforeRequest: { $0.bearerAuth(token) }, afterResponse: verify)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
