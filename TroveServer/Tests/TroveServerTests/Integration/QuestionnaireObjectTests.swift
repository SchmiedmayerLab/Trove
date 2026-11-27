// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import TroveServer
import VaporTesting


/// Completions read the pinned Questionnaire from the derived artifact cache instead of unpacking the archive.
struct QuestionnaireObjectTests {
    private typealias Fixture = TaskCompletionFixture

    /// Publication writes the entry; a completion then reads it and not the archive.
    @Test
    func publicationPrefillsTheObjectAndCompletionReadsIt() async throws {
        let storage = PublicationStorage()
        try await PublicationWorkflowFixtures.withApp(storageProvider: storage, validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            let publication = try #require(try await PublishedStudy.find(assignment.task.publicationId.requireId(), on: app.db))
            let key = DerivedArtifactCache.key(source: publication.bundleDigest, kind: .questionnaire, content: assignment.task.sha256)
            #expect(FHIRValidationClient.digest(try await storage.downloadBuffered(key: key)) == assignment.task.sha256)
            let archiveReads = await storage.downloads.filter { $0 == publication.bundleKey }.count
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let session = try await Fixture.start(assignment.task, on: app)
                _ = try await Fixture.complete(assignment.task.id, session: session, bytes: Fixture.response(for: session), on: app)
            }
            #expect(await storage.downloads.filter { $0 == publication.bundleKey }.count == archiveReads)
            #expect(await storage.downloads.contains(key))
        }
    }

    /// A missing entry or one whose bytes do not match its digest is derived from the archive once and written back.
    @Test(arguments: [false, true])
    func missingOrAlteredObjectIsWrittenBackFromTheArchive(altered: Bool) async throws {
        let storage = PublicationStorage()
        try await PublicationWorkflowFixtures.withApp(storageProvider: storage, validator: QuestionnaireWorkerReply.validator()) { app, researcher in
            let assignment = try await Fixture.assign(app: app, researcher: researcher)
            let publication = try #require(try await PublishedStudy.find(assignment.task.publicationId.requireId(), on: app.db))
            let key = DerivedArtifactCache.key(source: publication.bundleDigest, kind: .questionnaire, content: assignment.task.sha256)
            if altered {
                try await storage.uploadBuffered(data: Data("{}".utf8), key: key, contentType: "application/fhir+json")
            } else {
                await storage.delete(key: key)
            }
            let archiveReads = await storage.downloads.filter { $0 == publication.bundleKey }.count
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let session = try await Fixture.start(assignment.task, on: app)
                _ = try await Fixture.complete(assignment.task.id, session: session, bytes: Fixture.response(for: session), on: app)
            }
            #expect(await storage.downloads.filter { $0 == publication.bundleKey }.count == archiveReads + 1)
            #expect(FHIRValidationClient.digest(try await storage.downloadBuffered(key: key)) == assignment.task.sha256)
        }
    }
}
