//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import Testing
import TroveAPIClient
@testable import TroveServer
import VaporTesting


struct RecordBundleRecoveryTests {
    @Test
    func kindsTravelSeparatelyAndRetractionsSuppressBothMeasurements() async throws {
        try await Self.exercise(fullValidation: false)
    }

    @Test(.enabled(if: Environment.get("TROVE_TEST_VALIDATOR_ASSETS") != nil, "Requires the isolated pinned full validator"))
    func fullValidatorAcceptsPackedRecordsAndRetractions() async throws {
        try await Self.exercise(fullValidation: true)
    }
}


extension RecordBundleRecoveryTests {
    private static func exercise(fullValidation: Bool) async throws {
        try await TestApp.withApp(
            token: .participant(subject: "test-participant"), validator: fullValidation ? nil : ClinicalEventBatchTests.validator()
        ) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trove-bundle-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let scope = try EventDeliveryJournal.Scope(
                backend: Servers.Server1.url().absoluteString, issuer: TestApp.issuer, subject: "test-participant"
            )
            try await ClientDeliveryRecoveryTests.withJournal(
                url: directory.appendingPathComponent("journal.sqlite"), scope: scope, mode: .createNew
            ) { journal in
                let setup = try await journal.createSource(localID: fixture.source.registrationID, queryDefinition: Data([1]))
                try await journal.confirmSource(.init(fixture.source), for: setup)
                let payloads = try Self.payloads(fixture, fullValidation: fullValidation)
                let checkpoint = try await journal.checkpoint(for: fixture.source.id)
                _ = try await journal.stage(from: checkpoint, nextCursor: Data([2]), payloads: payloads)
                let transport = ReceiverClientTransport(application: app, token: token)
                let outcomes = try await ClientDeliveryRecoveryTests.drainer(journal: journal, transport: transport).drain()
                #expect(outcomes.map(\.status) == Array(repeating: .delivered, count: 4))
                let bodies = await transport.batchBodies
                try #require(bodies.count == 2)
                for (body, kind) in zip(bodies, [ExchangeGraph.Kind.active, .retraction]) {
                    let request = try JSONDecoder().decode(Components.Schemas.RecordBundleSubmission.self, from: body)
                    let bytes = try #require(Data(base64Encoded: request.bundleBase64))
                    #expect(try ExchangeGraph(validating: bytes, kind: kind).records().count == 2)
                    if fullValidation { _ = try await FHIRValidationClient(application: app).validate(bytes) }
                }
                let store = ClinicalEventStore(database: app.db)
                for study in fixture.studyIDs { #expect(try await store.effectiveGrantCount(studyID: study) == 0) }
                #expect(try await journal.pendingDeliveryIDs().isEmpty)
            }
        }
    }

    private static func payloads(
        _ fixture: ClinicalEventStoreTests.Fixture, fullValidation: Bool
    ) throws -> [EventDeliveryJournal.Payload] {
        let active = try (1...2).map { index in
            try fullValidation
                ? ImmutablePointEventFixture.bytes(source: fixture.source, sequence: UInt64(index), recordID: "measurement-\(index)")
                : LocalPointEventFixture.bytes(source: fixture.source, sequence: UInt64(index), recordID: "measurement-\(index)")
        }
        let payloads = try active.map { bytes in
            let projection = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "fixture")
            return EventDeliveryJournal.Payload(bytes: bytes, targets: fixture.targets(for: projection).map {
                .init(consentID: $0.consentID, outputFullURLs: $0.outputFullURLs)
            })
        }
        return try payloads + active.map { .init(bytes: try RetractionEventFixture.bytes(activeBytes: $0), targets: []) }
    }
}
