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
@testable import TroveServer
import Vapor


/// Real custody transactions with synthetic validator replies; no claim of full-IG validation.
struct SourceInstallationAdmissionTests {
    @Test
    func revocationDuringValidationPreventsAllCustodyAndGrantMutations() async throws {
        try await Self.withFixture { app, fixture in
            let validator = ClinicalEventBatchTests.validator {
                _ = try await app.grove[SourceInstallationService.self].revoke(registrationID: fixture.installationID)
            }
            let submission = try ClinicalEventBatchTests.submission(LocalPointEventFixture.bytes(source: fixture.source), fixture: fixture)
            await #expect {
                try await TestApp.clinicalService(database: app.db, validator: validator).accept(
                    submission: submission, sourceID: fixture.source.id, installation: fixture.installation
                )
            } throws: { ($0 as? ServerError)?.status.code == 409 }
            try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
            try await Self.expectAdmissionAudits(0, on: app)
        }
    }

    @Test(arguments: [false, true])
    func revocationBetweenRecordsPreservesOnlyTheCommittedPrefix(bundle: Bool) async throws {
        try await Self.withFixture { app, fixture in
            let counter = ValidationCounter()
            let validator = ClinicalEventBatchTests.validator {
                if await counter.next() == 2 {
                    _ = try await app.grove[SourceInstallationService.self].revoke(registrationID: fixture.installationID)
                }
            }
            let submissions = try (1...3).map {
                try ClinicalEventBatchTests.submission(
                    LocalPointEventFixture.bytes(source: fixture.source, sequence: UInt64($0), recordID: "sample-\($0)"), fixture: fixture
                )
            }
            let service = TestApp.clinicalService(database: app.db, validator: validator)
            let results = if bundle {
                try await service.acceptBundle(
                    ClinicalRecordBundleTests.bundle(submissions, sourceID: fixture.source.id),
                    sourceID: fixture.source.id,
                    installation: fixture.installation
                )
            } else {
                try await service.acceptBatch(submissions, sourceID: fixture.source.id, installation: fixture.installation)
            }
            try #require(results.count == 3)
            guard case .EventReceipt(let receipt) = results[0] else {
                Issue.record("First record was not retained")
                return
            }
            #expect(results.dropFirst().map(\.problemStatus) == [409, 409])
            #expect(await counter.count == 2)
            try await Self.expectRecoveredReceipt(receipt, submission: submissions[0], sourceID: fixture.source.id, on: app)
            try await ClinicalEventStoreTests.expectRows(events: 1, nodes: receipt.nodeCount, facts: 1, grants: 2, on: app.db)
            try await Self.expectAdmissionAudits(3, on: app)
        }
    }

    @Test
    func revokingOneInstallationPreservesAnotherInstallationsDeduplicationAndAdmission() async throws {
        try await Self.withFixture { app, fixture in
            let installationID = UUID()
            let other = try await app.grove[SourceBindingService.self].registerSource(registrationID: installationID)
            #expect(other.id == fixture.source.id)
            let proof = try SourceBindingFixture.proof(installationID)
            let store = ClinicalEventStore(database: app.db)
            let event = try ClinicalEventStoreTests.event(source: fixture.source)
            let receipt = try await store.accept(
                event, sourceID: other.id, targets: fixture.targets, installation: fixture.installation
            )
            _ = try await app.grove[SourceInstallationService.self].revoke(registrationID: fixture.installationID)
            await #expect {
                try await store.accept(event, sourceID: other.id, targets: fixture.targets, installation: fixture.installation)
            } throws: { ($0 as? ServerError)?.status.code == 409 }
            #expect(try await store.accept(event, sourceID: other.id, targets: fixture.targets, installation: proof) == receipt)
            _ = try await store.accept(
                ClinicalEventStoreTests.event(source: other, sequence: 2), sourceID: other.id, targets: fixture.targets, installation: proof
            )
            try await ClinicalEventStoreTests.expectRows(events: 2, nodes: 4, facts: 2, grants: 4, on: app.db)
            try await Self.expectAdmissionAudits(6, on: app)
        }
    }

    @Test
    func revokedInstallationCanReplayAnAttributionButCannotGrantAgain() async throws {
        try await Self.withFixture { app, fixture in
            let sourceID = fixture.source.id, proof = fixture.installation
            let receipt = try await ClinicalEventStore(database: app.db).accept(
                ClinicalEventStoreTests.event(source: fixture.source), sourceID: sourceID, targets: [fixture.targets[0]], installation: proof
            )
            let store = ClinicalAttributionStore(database: app.db)
            let command = UUID(), eventID = receipt.eventID
            let targets = [fixture.targets[1]]
            let first = try await store.attribute(eventID: eventID, sourceID: sourceID, commandID: command, targets: targets, installation: proof)
            _ = try await app.grove[SourceInstallationService.self].revoke(registrationID: fixture.installationID)
            let replay = try await store.attribute(eventID: eventID, sourceID: sourceID, commandID: command, targets: targets, installation: proof)
            #expect(replay == first)
            await #expect {
                try await store.attribute(eventID: eventID, sourceID: sourceID, commandID: UUID(), targets: targets, installation: proof)
            } throws: { ($0 as? ServerError)?.status.code == 409 }
            try await ClinicalEventStoreTests.expectRows(events: 1, nodes: 2, facts: 1, grants: 2, on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM clinical_attribution_commands").first())
            #expect(try row.decode(column: "count", as: Int.self) == 1)
        }
    }
}


extension SourceInstallationAdmissionTests {
    private actor ValidationCounter {
        private(set) var count = 0
        func next() -> Int { count += 1; return count }
    }

    private static func withFixture(
        _ test: @escaping @Sendable (Application, ClinicalEventStoreTests.Fixture) async throws -> Void
    ) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) { try await test(app, fixture) }
        }
    }

    private static func expectRecoveredReceipt(
        _ receipt: Components.Schemas.EventReceipt, submission: Components.Schemas.EventSubmission, sourceID: UUID, on app: Application
    ) async throws {
        let lookup = try ClinicalEventReceiptStore.Lookup(
            system: receipt.producerEventIdentifier.system,
            value: receipt.producerEventIdentifier.value,
            digest: receipt.payloadSHA256,
            targets: submission.targets.map { try $0.domainTarget }
        )
        let recovered = try await ClinicalEventReceiptStore(database: app.db).lookup(lookup, sourceID: sourceID)
        #expect(recovered.apiRepresentation == receipt)
    }

    private static func expectAdmissionAudits(_ count: Int, on app: Application) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        let row = try #require(try await sql.raw("""
            SELECT COUNT(*) AS count FROM audit_events WHERE action IN ('clinical.event.accepted', 'study.data.granted')
            """)
            .first())
        #expect(try row.decode(column: "count", as: Int.self) == count)
    }
}
