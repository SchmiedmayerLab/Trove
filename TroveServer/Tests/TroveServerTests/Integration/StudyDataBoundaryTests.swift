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


struct StudyDataBoundaryTests {
    @Test
    func capacityFailureHasNoPartialDisclosureAndSmallerPagesRemainUsable() async throws {
        try await TestApp.withApp(token: StudyDataFixture.reader) { app, bearer in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            for index in 1...7 {
                try await StudyDataFixture.accept(fixture, on: app, sequence: UInt64(index), recordID: "large-\(index)", noteBytes: 3 * 1024 * 1024)
            }
            let path = "\(apiBasePath)/studies/\(fixture.studyIDs[0])/data"
            try await app.test(.GET, path + "?limit=7", beforeRequest: { $0.bearerAuth(bearer) }) {
                #expect($0.status == .serviceUnavailable)
                #expect(!$0.body.string.contains("bundleBase64"))
                #expect($0.body.string.contains("response limit"))
            }
            #expect(try await StudyDataFixture.disclosureCount(on: app.db) == 0)
            try await app.test(.GET, path + "?limit=1", beforeRequest: { $0.bearerAuth(bearer) }) {
                #expect($0.status == .ok)
                #expect($0.body.readableBytes <= StudyDataExportStore.maximumResponseBytes)
                let page = try $0.content.decode(Components.Schemas.StudyDataPage.self)
                #expect(page.records.count == 1 && page.nextBefore != nil)
                #expect(try await StudyDataFixture.disclosureCount(on: app.db) == 1)
            }
        }
    }

    @Test
    func overlappingConsentRevisionsExportOneMeasurementWithBothHistoricalProtocols() async throws {
        try await TestApp.withApp(token: StudyDataFixture.reader) { app, bearer in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let event = try await StudyDataFixture.accept(fixture, on: app)
            let receipt = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await ClinicalEventStore(database: app.db).accept(
                    event, sourceID: fixture.source.id, targets: fixture.targets(for: event), installation: fixture.installation
                )
            }
            try await StudyDataQueryTests.addHistoricalGrant(fixture: fixture, receipt: receipt, on: app, outputs: event.outputs.map(\.fullURL))
            try await app.test(.GET, "\(apiBasePath)/studies/\(fixture.studyIDs[0])/data", beforeRequest: { $0.bearerAuth(bearer) }) {
                #expect($0.status == .ok)
                let page = try $0.content.decode(Components.Schemas.StudyDataPage.self)
                #expect(page.records.count == 1 && page.records[0].outputs.count == 1)
                let resources = try StudyDataFixture.resources(#require(page.records.first))
                #expect(resources.filter { $0["resourceType"] as? String == "Observation" }.count == 1)
                let versions = resources.filter { $0["resourceType"] as? String == "PlanDefinition" }.compactMap { $0["version"] as? String }
                #expect(Set(versions) == ["1", "2"])
                let provenance = try #require(resources.first { $0["resourceType"] as? String == "Provenance" && $0["policy"] != nil })
                #expect((provenance["entity"] as? [Any])?.count == 2)
            }
        }
    }

    @Test
    func unknownAndOtherStudyCursorsCannotReadData() async throws {
        try await TestApp.withApp(token: StudyDataFixture.reader) { app, bearer in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await StudyDataFixture.accept(fixture, on: app)
            let first = try await StudyDataQuery(database: app.db).page(studyID: fixture.studyIDs[0])
            let node = try #require(first.outputs.first).nodeID
            let original = try #require(try await Study.find(fixture.studyIDs[0], on: app.db))
            let separate = try await StudyFixtures.createStudy(on: app.db, groupId: original.$group.id)
            for cursor in [node, UUID()] {
                try await app.test(.GET, "\(apiBasePath)/studies/\(try separate.requireID())/data?before=\(cursor)", beforeRequest: {
                    $0.bearerAuth(bearer)
                }) { #expect($0.status == .badRequest) }
            }
            #expect(try await StudyDataFixture.disclosureCount(on: app.db) == 0)
        }
    }
}
