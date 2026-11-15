//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SQLKit
import Testing
import TroveAPIServer
import TroveAPITypes
@testable import TroveServer
import VaporTesting


/// Grove's sync identifier golden record, rekeyed to a registered source, through custody and a study export.
struct SyncIdentifierCustodyTests {
    @Test
    func syncIdentifierIsRetainedAndExportedLikeTheNativeUUID() async throws {
        try await TestApp.withApp(token: StudyDataFixture.reader) { app, bearer in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let nativeSystem = try Components.Schemas.ParticipantSource(fixture.source).nativeRecordIdentifierSystem().rawValue
            let rekeyed = try LocalPointEventFixture.bytes(source: fixture.source, fixtureURL: SyncIdentifierFixture.url())
            let bytes = Data(String(decoding: rekeyed, as: UTF8.self).replacingOccurrences(
                of: SyncIdentifierFixture.nativeSystem, with: nativeSystem
            ).utf8)
            let syncSystem = nativeSystem + "/" + FHIRSyncRecordIdentifier.systemPathSegment + "/org.example.writer"
            let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-only")
            #expect(event.syncRecordIdentifiers == [.init(system: syncSystem, value: SyncIdentifierFixture.value)])
            let native = try #require(event.nativeRecordIdentifiers.first)
            let targets = fixture.targets(for: event, studies: [0])
            let receipt = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let store = ClinicalEventStore(database: app.db)
                let receipt = try await store.accept(event, sourceID: fixture.source.id, targets: targets, installation: fixture.installation)
                #expect(try await store.accept(event, sourceID: fixture.source.id, targets: targets, installation: fixture.installation) == receipt)
                return receipt
            }
            let sql = try #require(app.db as? any SQLDatabase)
            let row = try #require(try await sql.raw("SELECT raw_bytes FROM clinical_events WHERE id = \(bind: receipt.eventID)").first())
            #expect(try row.decode(column: "raw_bytes", as: Data.self) == bytes)

            let response = try await app.testing().sendRequest(
                .GET, "\(apiBasePath)/studies/\(fixture.studyIDs[0])/data", beforeRequest: { $0.bearerAuth(bearer) }
            )
            #expect(response.status == .ok)
            let page = try response.content.decode(Components.Schemas.StudyDataPage.self)
            let record = try #require(page.records.first)
            let observation = try #require(try StudyDataFixture.resources(record).first { $0["resourceType"] as? String == "Observation" })
            let identifiers = try #require(observation["identifier"] as? [[String: Any]])
            let exported = identifiers.filter(SyncIdentifierFixture.isSyncIdentifier)
            #expect(exported.count == 1)
            #expect(exported.first?["system"] as? String == syncSystem && exported.first?["value"] as? String == SyncIdentifierFixture.value)
            #expect(identifiers.contains { $0["system"] as? String == native.system && $0["value"] as? String == native.value })
        }
    }
}
