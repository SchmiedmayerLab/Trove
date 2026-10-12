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
import TroveAPIClient
@testable import TroveServer
import VaporTesting


/// Real journal, generated HTTP client, authenticated router and receiver persistence.
/// The normal lane substitutes only the validator transport; the opt-in lane uses the pinned full validator.
struct ClientDeliveryRecoveryTests {
    private struct Staged: Sendable {
        let identifiers: [UUID]
        let payloads: [EventDeliveryJournal.Payload]
        let checkpoint: EventDeliveryJournal.Checkpoint
    }

    @Test(arguments: [false, true])
    func lostPartialBatchRecoversAfterWithdrawalAndReopening(revokeSource: Bool) async throws {
        try await Self.exerciseRecovery(revokeSource: revokeSource, fullValidation: false)
    }

    @Test(.enabled(if: Environment.get("TROVE_TEST_VALIDATOR_ASSETS") != nil, "Requires the isolated pinned full validator"))
    func fullValidatorClientAndReceiverRecovery() async throws {
        try #require(Environment.get("FHIR_VALIDATOR_URL") != nil && Environment.get("FHIR_VALIDATOR_IDENTITY") != nil)
        try await Self.exerciseRecovery(revokeSource: true, fullValidation: true)
    }

    @Test
    func authenticationFailureRetainsTheWholeBatchAndStopsFurtherRequests() async throws {
        try await TestApp.withApp(token: .none, validator: ClinicalEventBatchTests.validator()) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("trove-client-auth-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let scope = try EventDeliveryJournal.Scope(
                backend: Servers.Server1.url().absoluteString, issuer: TestApp.issuer, subject: "test-participant"
            )
            try await Self.withJournal(url: directory.appendingPathComponent("delivery.sqlite"), scope: scope, mode: .createNew) { journal in
                let staged = try await Self.stage(journal: journal, fixture: fixture, fullValidation: false)
                let transport = ReceiverClientTransport(application: app, token: token)
                let drainer = try Self.drainer(journal: journal, transport: transport)
                for _ in 0..<2 {
                    await #expect(throws: EventDeliveryDrainer.DeliveryError.authenticationRequired) { try await drainer.drain() }
                }
                #expect(await transport.paths.count == 1)
                for id in staged.identifiers {
                    #expect(try await journal.receipt(for: id) == nil)
                    #expect(try await journal.status(for: id) == .pending)
                    let attempt = try #require(try await journal.prepareAttempt(id))
                    #expect(attempt.custodyWasUncertain)
                    #expect(staged.payloads.contains { $0.bytes == attempt.bytes })
                }
                try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
            }
        }
    }
}


extension ClientDeliveryRecoveryTests {
    private static func exerciseRecovery(revokeSource: Bool, fullValidation: Bool) async throws {
        try await TestApp.withApp(
            token: .participant(subject: "test-participant"), validator: fullValidation ? nil : ClinicalEventBatchTests.validator()
        ) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("trove-client-receiver-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("delivery.sqlite")
            let scope = try EventDeliveryJournal.Scope(
                backend: Servers.Server1.url().absoluteString, issuer: TestApp.issuer, subject: "test-participant"
            )
            let staged = try await withJournal(url: url, scope: scope, mode: .createNew) { journal in
                let staged = try await stage(journal: journal, fixture: fixture, fullValidation: fullValidation)
                try await loseReply(staged, journal: journal, on: app, token: token)
                try await expectStored(fixture: fixture, payload: staged.payloads[0], on: app)
                try await withdraw(fixture: fixture, on: app, token: token, revokeSource: revokeSource)
                return staged
            }
            try await TestDatabase.withRestartedApplication(app) { reopened in
                try await configureServices(
                    for: reopened,
                    storageProvider: InMemoryObjectStorageProvider(),
                    validator: fullValidation ? FHIRValidationClient(application: reopened) : ClinicalEventBatchTests.validator()
                )
                _ = try await TestApp.configureTransport(for: reopened)
                try await expectSource(fixture.source, revoked: revokeSource, on: reopened, token: token)
                try await withJournal(url: url, scope: scope, mode: .openExisting) { journal in
                    try await recover(staged, journal: journal, fixture: fixture, receiver: (reopened, token), revokeSource: revokeSource)
                }
            }
        }
    }
}


extension ClientDeliveryRecoveryTests {
    private static func expectSource(_ source: SourceBinding, revoked: Bool, on app: Application, token: String?) async throws {
        try await app.test(.GET, "\(apiBasePath)/participant/sources/\(source.id)", beforeRequest: { $0.bearerAuth(token) }) { response in
            #expect(response.status == .ok)
            let binding = try response.content.decode(Components.Schemas.ParticipantSource.self)
            let expectedSystems = try SourceIdentityNamespaces.assign(root: source.identifierRoot, registrationID: source.registrationID)
            #expect(try binding.identifierSystems() == expectedSystems)
            #expect((binding.revokedAt != nil) == revoked)
        }
    }

    private static func loseReply(_ staged: Staged, journal: EventDeliveryJournal, on app: Application, token: String?) async throws {
        let transport = ReceiverClientTransport(application: app, token: token, loseBatchResponse: true)
        let results = try await drainer(journal: journal, transport: transport).drain()
        #expect(results.map(\.deliveryID) == staged.identifiers)
        for result in results {
            guard case .waiting = result.status else {
                Issue.record("A lost response must leave every submitted member uncertain")
                continue
            }
            #expect(try await journal.receipt(for: result.deliveryID) == nil)
        }
        let batches = await transport.batchBodies
        try #require(batches.count == 1)
        try expectPayloads(batches[0], equalTo: staged.payloads)
    }

    private static func stage(
        journal: EventDeliveryJournal, fixture: ClinicalEventStoreTests.Fixture, fullValidation: Bool
    ) async throws -> Staged {
        let setup = try await journal.createSource(localID: fixture.source.registrationID, queryDefinition: Data("recovery-fixture-v1".utf8))
        try await journal.confirmSource(.init(fixture.source), for: setup)
        let payloads = try (1...2).map { sequence in
            let bytes = try fullValidation
                ? ImmutablePointEventFixture.bytes(source: fixture.source, sequence: UInt64(sequence))
                : LocalPointEventFixture.bytes(source: fixture.source, sequence: UInt64(sequence))
            let projection = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-target-selection-only")
            let targets = sequence == 1 ? fixture.targets(for: projection) : [
                ClinicalEventTarget(consentID: UUID(), outputFullURLs: projection.outputs.map(\.fullURL))
            ]
            return EventDeliveryJournal.Payload(bytes: bytes, targets: targets.map {
                .init(consentID: $0.consentID, outputFullURLs: $0.outputFullURLs)
            })
        }
        let checkpoint = try await journal.checkpoint(for: fixture.source.id)
        let identifiers = try await journal.stage(
            from: checkpoint, nextCursor: Data("delta-2".utf8), payloads: payloads
        )
        return Staged(identifiers: identifiers, payloads: payloads, checkpoint: try await journal.checkpoint(for: fixture.source.id))
    }

    private static func recover(
        _ staged: Staged,
        journal: EventDeliveryJournal,
        fixture: ClinicalEventStoreTests.Fixture,
        receiver: (Application, String?),
        revokeSource: Bool
    ) async throws {
        let (app, token) = receiver
        #expect(try await journal.checkpoint(for: fixture.source.id) == staged.checkpoint)
        let transport = ReceiverClientTransport(application: app, token: token)
        let results = try await drainer(journal: journal, transport: transport, now: Date().addingTimeInterval(600)).drain()
        #expect(results.map(\.deliveryID) == staged.identifiers)
        #expect(results.map(\.status) == [.delivered, .blocked(.rejected(statusCode: revokeSource ? 409 : 404))])
        let receipt = try #require(try await journal.receipt(for: staged.identifiers[0]))
        try EventSubmissionCommitment(
            sourceID: fixture.source.id, originalBytes: staged.payloads[0].bytes, targets: staged.payloads[0].targets
        ).verify(receipt)
        #expect(try await journal.receipt(for: staged.identifiers[1]) == nil)
        let paths = await transport.paths
        #expect(paths.filter { $0.hasSuffix("/event-receipts/lookup") }.count == 2)
        let batches = await transport.batchBodies
        try #require(batches.count == 1)
        try expectPayloads(batches[0], equalTo: [staged.payloads[1]])
        try await expectStored(fixture: fixture, payload: staged.payloads[0], on: app)
        let store = ClinicalEventStore(database: app.db)
        #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 0)
        #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[1]) == 1)
        #expect(try await journal.pruneDelivered() == 1)
        #expect(try await journal.checkpoint(for: fixture.source.id) == staged.checkpoint)
        #expect(try await journal.status(for: staged.identifiers[1]) == .blocked(.rejected(statusCode: revokeSource ? 409 : 404)))
    }

    private static func withdraw(
        fixture: ClinicalEventStoreTests.Fixture, on app: Application, token: String?, revokeSource: Bool
    ) async throws {
        try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(fixture.enrollmentIDs[0])/withdraw", beforeRequest: {
            $0.bearerAuth(token)
        }) { #expect($0.status == .ok) }
        if revokeSource {
            try await app.test(.POST, "\(apiBasePath)/participant/sources/\(fixture.source.id)/revoke", beforeRequest: {
                $0.bearerAuth(token)
            }) { #expect($0.status == .ok) }
        }
    }

    private static func expectStored(
        fixture: ClinicalEventStoreTests.Fixture, payload: EventDeliveryJournal.Payload, on app: Application
    ) async throws {
        let commitment = try EventSubmissionCommitment(sourceID: fixture.source.id, originalBytes: payload.bytes, targets: payload.targets)
        try await ClinicalEventStoreTests.expectRows(events: 1, nodes: commitment.nodeCount, facts: 1, grants: 2, on: app.db)
        let sql = try #require(app.db as? any SQLDatabase)
        let rows = try await sql.raw("SELECT raw_bytes FROM clinical_events").all()
        #expect(try rows.map { try $0.decode(column: "raw_bytes", as: Data.self) } == [payload.bytes])
    }

    static func expectPayloads(_ body: Data, equalTo payloads: [EventDeliveryJournal.Payload]) throws {
        let submission = try JSONDecoder().decode(Components.Schemas.EventBatchSubmission.self, from: body)
        #expect(submission.events.map { Data(base64Encoded: $0.eventBase64) } == payloads.map(\.bytes))
        let expectedTargets = try payloads.map { payload in
            try EventTargetIntent(targets: payload.targets).targets.map {
                Components.Schemas.EventTarget(consentId: $0.consentID.uuidString.lowercased(), outputFullUrls: $0.outputFullURLs)
            }
        }
        #expect(submission.events.map(\.targets) == expectedTargets)
    }

    static func drainer(
        journal: EventDeliveryJournal, transport: ReceiverClientTransport, now: Date = Date()
    ) throws -> EventDeliveryDrainer {
        try .init(
            journal: journal,
            scope: journal.scope,
            client: TroveAPIClient.Client(serverURL: Servers.Server1.url(), configuration: .trove, transport: transport),
            validateSession: {},
            now: { now }
        )
    }

    static func withJournal<Result>(
        url: URL,
        scope: EventDeliveryJournal.Scope,
        mode: EventDeliveryJournal.OpenMode,
        operation: (EventDeliveryJournal) async throws -> Result
    ) async throws -> Result {
        let journal = try EventDeliveryJournal(url: url, scope: scope, mode: mode)
        do {
            let result = try await operation(journal)
            await journal.close()
            return result
        } catch {
            await journal.close()
            throw error
        }
    }
}
