//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


/// Every step uses authenticated HTTP and the full pinned validator, including replay.
/// Each case owns its database. The expected state is read from the IG corpus unchanged.
struct ReceiverRevisionCorpusTests {
    @Test(
        .enabled(if: Environment.get("TROVE_TEST_LIFECYCLE_CORPUS") != nil, "Requires the pinned receiver lifecycle corpus and validator"),
        arguments: 0..<35
    )
    func completeRevisionSequenceAndRestart(index: Int) async throws {
        try #require(Environment.get("TROVE_TEST_POSTGRES_PORT") != nil)
        try #require(Environment.get("FHIR_VALIDATOR_URL") != nil && Environment.get("FHIR_VALIDATOR_IDENTITY") != nil)
        let (corpus, root) = try ReceiverRevisionCorpus.load()
        let sequence = corpus.sequences[index]
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            app.logger.info("Receiver revision corpus: \(sequence.id)")
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let prepared = try corpus.prepare(sequence: sequence, source: fixture.source, root: root)
            var receipts: [String: Components.Schemas.EventReceipt] = [:]
            var previouslyVisible: Set<String> = []
            for step in sequence.steps {
                let event = try #require(prepared[step.event])
                let receipt = try await Self.upload(event, fixture: fixture, token: token, on: app)
                if let previous = receipts[step.event] { #expect(receipt == previous) }
                receipts[step.event] = receipt
                let assertion = ReceiverRevisionAssertions(fixture: fixture, prepared: prepared, receipts: receipts)
                let visible = try await assertion.check(step.expect, on: app.db)
                #expect(visible.subtracting(previouslyVisible) == assertion.keys(step.expect.newlyVisible))
                previouslyVisible = visible
            }
            let accepted = receipts
            let final = try #require(sequence.steps.last).expect
            try await TestDatabase.withRestartedApplication(app) { reopened in
                try await configureServices(
                    for: reopened, storageProvider: InMemoryObjectStorageProvider(), validator: FHIRValidationClient(application: reopened)
                )
                _ = try await TestApp.configureTransport(for: reopened)
                let assertion = ReceiverRevisionAssertions(fixture: fixture, prepared: prepared, receipts: accepted)
                let before = try await assertion.check(final, on: reopened.db)
                for step in sequence.steps {
                    let receipt = try await Self.upload(try #require(prepared[step.event]), fixture: fixture, token: token, on: reopened)
                    #expect(receipt == accepted[step.event])
                    #expect(try await assertion.check(final, on: reopened.db) == before)
                }
            }
        }
    }
}


extension ReceiverRevisionCorpusTests {
    private static func upload(
        _ event: ReceiverRevisionCorpus.PreparedEvent,
        fixture: ClinicalEventStoreTests.Fixture,
        token: String?,
        on app: Application
    ) async throws -> Components.Schemas.EventReceipt {
        var receipt: Components.Schemas.EventReceipt?
        try await app.test(.POST, "\(apiBasePath)/participant/sources/\(fixture.source.id)/events", beforeRequest: {
            $0.bearerAuth(token)
            try $0.encodeJSONBody(Components.Schemas.EventSubmission(
                eventBase64: event.bytes.base64EncodedString(),
                targets: [.init(consentId: fixture.consentIDs[0].uuidString, outputFullUrls: event.selected)]
            ))
        }) { response in
            try #require(response.status == .ok)
            receipt = try response.content.decode(Components.Schemas.EventReceipt.self)
        }
        return try #require(receipt)
    }
}
