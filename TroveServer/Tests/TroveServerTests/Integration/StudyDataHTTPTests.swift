//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import ModelsR4
import SQLKit
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


struct StudyDataHTTPTests {
    @Test
    func eachStudyReceivesItsOwnContextAndCommittedDisclosureIntent() async throws {
        try await TestApp.withApp(token: StudyDataFixture.reader) { app, bearer in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let event = try await StudyDataFixture.accept(fixture, on: app)
            for index in fixture.studyIDs.indices {
                let study = fixture.studyIDs[index]
                try await app.test(.GET, "\(apiBasePath)/studies/\(study)/data", beforeRequest: { $0.bearerAuth(bearer) }) { response in
                    #expect(response.status == .ok)
                    #expect(response.headers.first(name: .cacheControl) == "no-store")
                    let page = try response.content.decode(Components.Schemas.StudyDataPage.self)
                    #expect(page.studyId == study.uuidString && page.records.count == 1 && page.versions == .current)
                    let record = try #require(page.records.first)
                    #expect(record.outputs.count == 1 && record.outputs[0].isCurrent)
                    #expect(record.outputs[0].sourceProfiles.contains(CollectionRequirement.supportedProfile))
                    let bytes = try #require(Data(base64Encoded: record.bundleBase64))
                    let bundle = try JSONDecoder().decode(ModelsR4.Bundle.self, from: bytes)
                    #expect(bundle.type.value == .collection)
                    #expect(bundle.identifier?.value?.value?.string == record.id.lowercased())
                    let text = String(decoding: bytes, as: UTF8.self)
                    #expect(text.contains(NativeIdentifierFixture.uuid))
                    #expect(text.contains(fixture.enrollmentIDs[index].uuidString.lowercased()))
                    #expect(!text.contains(fixture.enrollmentIDs[1 - index].uuidString.lowercased()))
                    #expect(!text.contains(fixture.source.participantIdentifierValue))
                    let sql = try #require(app.db as? any SQLDatabase)
                    let audit = try #require(try await sql.raw("""
                        SELECT outcome, study_id, actor_subject FROM audit_events
                        WHERE action = 'study.data.disclosure' AND target_id = \(bind: page.id.requireId())
                        """)
                        .first())
                    #expect(try audit.decode(column: "outcome", as: String.self) == "disclosure_intent")
                    #expect(try audit.decode(column: "study_id", as: UUID.self) == study)
                    #expect(try audit.decode(column: "actor_subject", as: String.self) == "researcher-test-user")
                    let retained = try #require(try await sql.raw("SELECT raw_bytes FROM clinical_events").first())
                    #expect(try retained.decode(column: "raw_bytes", as: Data.self) == event.rawBytes)
                }
            }
            #expect(try await StudyDataFixture.disclosureCount(on: app.db) == 2)
        }
    }

    @Test
    func currentHistoryWithdrawalAndRetractionUseCurrentAuthority() async throws {
        try await TestApp.withApp(token: StudyDataFixture.reader) { app, bearer in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let original = try await StudyDataFixture.accept(fixture, on: app, sequence: 1)
            try await StudyDataFixture.accept(fixture, on: app, sequence: 2)
            let path = "\(apiBasePath)/studies/\(fixture.studyIDs[0])/data"
            let current = try await Self.page(path, token: bearer, app: app)
            #expect(current.records.count == 1 && current.records.flatMap(\.outputs).allSatisfy(\.isCurrent))
            let history = try await Self.page(path + "?versions=history", token: bearer, app: app)
            #expect(history.records.count == 2)
            #expect(history.records.flatMap(\.outputs).filter(\.isCurrent).count == 1)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: fixture.enrollmentIDs[0])
            }
            let withdrawn = try await Self.page(path + "?versions=history", token: bearer, app: app)
            #expect(withdrawn.records.isEmpty)
            let other = "\(apiBasePath)/studies/\(fixture.studyIDs[1])/data"
            let retained = try await Self.page(other, token: bearer, app: app)
            #expect(retained.records.count == 1)
            try await StudyDataFixture.retract(original, fixture: fixture, on: app)
            let removed = try await Self.page(other + "?versions=history", token: bearer, app: app)
            #expect(removed.records.isEmpty)
        }
    }

    @Test
    func paginationHasNoSkippedOrRepeatedMeasurements() async throws {
        try await TestApp.withApp(token: StudyDataFixture.reader) { app, bearer in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            for index in 1...3 { try await StudyDataFixture.accept(fixture, on: app, sequence: UInt64(index), recordID: "record-\(index)") }
            let path = "\(apiBasePath)/studies/\(fixture.studyIDs[0])/data"
            let first = try await Self.page(path + "?limit=2", token: bearer, app: app)
            #expect(first.records.count == 2)
            let cursor = try #require(first.nextBefore)
            let second = try await Self.page(path + "?limit=2&before=" + cursor, token: bearer, app: app)
            #expect(second.records.count == 1 && second.nextBefore == nil)
            let identities = try (first.records + second.records).flatMap { record in
                try StudyDataFixture.resources(record).filter { $0["resourceType"] as? String == "Observation" }.map { resource in
                    let identifiers = try #require(resource["identifier"] as? [[String: Any]])
                    return try #require(identifiers.first { ($0["system"] as? String)?.contains("source-output") == true }?["value"] as? String)
                }
            }
            #expect(identities.count == 3 && Set(identities).count == 3)
        }
    }
}


extension StudyDataHTTPTests {
    private static func page(_ path: String, token: String?, app: Application) async throws -> Components.Schemas.StudyDataPage {
        let response = try await app.testing().sendRequest(.GET, path, beforeRequest: { $0.bearerAuth(token) })
        #expect(response.status == .ok)
        return try response.content.decode(Components.Schemas.StudyDataPage.self)
    }
}
