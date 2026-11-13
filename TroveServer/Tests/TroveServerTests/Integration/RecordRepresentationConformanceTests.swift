//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import OpenAPIRuntime
import Testing
import TroveAPIClient
@testable import TroveServer
import VaporTesting


struct RecordRepresentationConformanceTests {
    @Test(.enabled(if: Environment.get("TROVE_TEST_VALIDATOR_ASSETS") != nil, "Requires the isolated pinned full validator"))
    func fullValidatorAcceptsEnrollmentSnapshotsAndRepeatedRetractions() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let active = try Self.activeVariants(source: fixture.source)
            #expect(try ExchangeRecord(validating: active[0]).version == ExchangeRecord(validating: active[1]).version)
            let projection = try FHIRPointProjection.project(validatedBytes: active[0], validatorIdentity: "fixture")
            let targets = fixture.targets(for: projection)
            let retractions = try [1, 2].map { try RetractionEventFixture.bytes(activeBytes: active[0], sequence: UInt64($0)) }
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let service = try ClinicalEventService(database: app.db, validator: FHIRValidationClient(application: app))
                for (payloads, intent) in [(active, targets), (retractions, [])] {
                    let first = try await service.accept(body: HTTPBody(payloads[0]), sourceID: fixture.source.id, targets: intent)
                    let second = try await service.accept(body: HTTPBody(payloads[1]), sourceID: fixture.source.id, targets: intent)
                    #expect(first.eventID == second.eventID)
                    #expect(first.payloadSHA256 != second.payloadSHA256)
                    let replay = try await service.accept(body: HTTPBody(payloads[1]), sourceID: fixture.source.id, targets: intent)
                    #expect(replay == second)
                }
                let store = ClinicalEventStore(database: app.db)
                for study in fixture.studyIDs { #expect(try await store.effectiveGrantCount(studyID: study) == 0) }
            }
            try await Self.deliver(active: active, retractions: retractions, fixture: fixture, application: app, token: token)
            let retraction = try FHIRPointProjection.project(validatedBytes: retractions[0], validatorIdentity: "fixture")
            let nodeCount = projection.nodes.count + retraction.nodes.count
            try await ClinicalEventStoreTests.expectRows(events: 2, nodes: nodeCount, facts: 1, grants: 2, on: app.db)
        }
    }
}


extension RecordRepresentationConformanceTests {
    private static func activeVariants(source: SourceBinding) throws -> [Data] {
        let instant = Date()
        let original = try ImmutablePointEventFixture.bytes(source: source, effectiveAt: instant, sequence: 1)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trove-context-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("context.json")
        try RecordRepresentationFixture.enrollment(original).write(to: url)
        // The independent pinned IG generator replaces every synthetic key before full validation.
        let updated = try ImmutablePointEventFixture.bytes(source: source, effectiveAt: instant, fixtureURL: url, sequence: 1)
        return [original, updated]
    }
}


extension RecordRepresentationConformanceTests {
    private static func deliver(
        active: [Data],
        retractions: [Data],
        fixture: ClinicalEventStoreTests.Fixture,
        application: Application,
        token: String?
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trove-variants-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = try EventDeliveryJournal.Scope(backend: Servers.Server1.url().absoluteString, issuer: TestApp.issuer, subject: "test-participant")
        let journalURL = directory.appendingPathComponent("journal.sqlite")
        try await ClientDeliveryRecoveryTests.withJournal(url: journalURL, scope: scope, mode: .createNew) { journal in
            let setup = try await journal.createSource(localID: fixture.source.registrationID, queryDefinition: Data([1]))
            try await journal.confirmSource(.init(fixture.source), for: setup)
            let payloads = try (active + retractions).map { bytes in
                let projection = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "fixture")
                let targets = projection.retraction == nil ? fixture.targets(for: projection) : []
                return EventDeliveryJournal.Payload(bytes: bytes, targets: targets.map {
                    .init(consentID: $0.consentID, outputFullURLs: $0.outputFullURLs)
                })
            }
            let checkpoint = try await journal.checkpoint(for: fixture.source.id)
            let ids = try await journal.stage(from: checkpoint, nextCursor: Data([2]), payloads: payloads)
            let transport = ReceiverClientTransport(application: application, token: token)
            let results = try await ClientDeliveryRecoveryTests.drainer(journal: journal, transport: transport).drain()
            #expect(results.map(\.status) == Array(repeating: .delivered, count: 4))
            #expect(await transport.batchBodies.count == 4)
            var receipts: [Components.Schemas.EventReceipt] = []
            for id in ids { receipts.append(try #require(await journal.receipt(for: id))) }
            try #require(receipts.count == 4)
            #expect(receipts[0].eventId == receipts[1].eventId)
            #expect(receipts[2].eventId == receipts[3].eventId)
            #expect(Set(receipts.map(\.payloadSHA256)).count == 4)
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
        }
    }
}
