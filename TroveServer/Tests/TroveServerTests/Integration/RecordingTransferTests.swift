//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import OpenAPIRuntime
import SQLKit
import Testing
import TroveAPIServer
@testable import TroveServer
import Vapor


/// Transport receipts do not assert that these synthetic bytes are valid clinical recordings.
struct RecordingTransferTests {
    private static let bytes = Data("synthetic recording".utf8)
    private static let output = "urn:uuid:51d14bcb-d095-460a-89d8-4c1a9c4a3b99"

    @Test
    func lostResponseRetryAndLookupRecoverTheExactReceiptWithoutReadingOrGranting() async throws {
        try await Self.withFixture { app, fixture, service, declaration in
            let id = UUID()
            let receipt = try await service.upload(
                HTTPBody(Self.bytes), sourceID: fixture.source.id, transferID: id, declaration: declaration, installation: fixture.installation
            )
            let input = ObjectStorageStreamSource([String(decoding: Self.bytes, as: UTF8.self)])
            let replay = try await service.upload(
                input.body(length: .known(Int64(Self.bytes.count))),
                sourceID: fixture.source.id,
                transferID: id,
                declaration: declaration,
                installation: fixture.installation
            )
            #expect(replay == receipt)
            #expect(await input.reads == 0)
            #expect(receipt.declarationSHA256 == declaration.sha256)
            #expect(receipt.storedSHA256 == ArtifactStore.digest(Self.bytes))
            #expect(receipt.storedByteCount == Self.bytes.count)
            #expect(try await service.lookup(sourceID: fixture.source.id, transferID: id) == receipt)
            try await Self.expectCounts(transfers: 1, attempts: 1, receipts: 1, on: app)
            try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            let audit = try #require(try await sql.raw("""
                SELECT COUNT(*) AS count FROM audit_events WHERE action = 'recording.transfer.stored'
                """)
                .first())
            #expect(try audit.decode(column: "count", as: Int.self) == 1)
            #expect(try await StoredArtifact.find(receipt.artifactID, on: app.db)?.state == .ready)
        }
    }

    @Test(arguments: ["changed-bytes", "changed-path", "withdrawal", "revoked-installation", "wrong-proof", "wrong-length", "budget"])
    func rejectedTransfersDoNotReadTheBodyOrCreateNewAttempts(reason: String) async throws {
        try await Self.withFixture { app, fixture, service, declaration in
            let id = UUID()
            _ = try await service.upload(
                HTTPBody(Self.bytes), sourceID: fixture.source.id, transferID: id, declaration: declaration, installation: fixture.installation
            )
            if reason == "withdrawal" {
                _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: fixture.enrollmentIDs[0])
            }
            if reason == "revoked-installation" {
                _ = try await app.grove[SourceInstallationService.self].revoke(registrationID: fixture.installationID)
            }
            let candidate = try Self.declaration(
                fixture,
                at: declaration.output.effectiveAt,
                path: reason == "changed-path" ? "recordings/other.csv" : "recordings/route.csv",
                bytes: reason == "changed-bytes" ? Data("changed recording!!".utf8) : Self.bytes
            )
            let proof = reason == "wrong-proof" ? try SourceBindingFixture.proof(UUID()) : fixture.installation
            let testedService = reason == "budget"
                ? RecordingTransferService(database: app.db, storage: service.storage, limits: try .init(storedBytes: 1, sourceBytes: 1)) : service
            let input = ObjectStorageStreamSource([String(decoding: Self.bytes, as: UTF8.self)])
            await #expect(throws: (any Error).self) {
                try await testedService.upload(
                    input.body(length: .known(reason == "wrong-length" ? 1 : Int64(candidate.content.storedByteCount))),
                    sourceID: fixture.source.id,
                    transferID: id,
                    declaration: candidate,
                    installation: proof
                )
            }
            #expect(await input.reads == 0)
            try await Self.expectCounts(transfers: 1, attempts: 1, receipts: 1, on: app)
        }
    }

    @Test
    func interruptedAttemptHasNoReceiptAndExpiryFencesItsLateCompletion() async throws {
        try await Self.withFixture { app, fixture, service, declaration in
            try await Self.exerciseInterruptedAttempt(app, fixture: fixture, service: service, declaration: declaration)
        }
    }

    @Test(arguments: ["withdrawal", "revocation", "audit"])
    func authorityAndAuditFailuresAfterStreamingCannotIssueAReceipt(reason: String) async throws {
        try await Self.withFixture { app, fixture, service, declaration in
            let id = UUID()
            let attempt = try Self.attempt(await service.reserve(
                sourceID: fixture.source.id, transferID: id, declaration: declaration, installation: fixture.installation
            ))
            let artifacts = ArtifactStore(database: app.db, storage: service.storage)
            try await artifacts.uploadReservedRecording(HTTPBody(Self.bytes), reference: attempt.reference)
            if reason == "withdrawal" {
                _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: fixture.enrollmentIDs[0])
            } else if reason == "revocation" {
                _ = try await app.grove[SourceInstallationService.self].revoke(registrationID: fixture.installationID)
            } else {
                let sql = try #require(app.db as? any SQLDatabase)
                try await sql.raw("DROP TABLE audit_events").run()
            }
            await #expect(throws: (any Error).self) {
                try await service.complete(
                    attempt,
                    sourceID: fixture.source.id,
                    transferID: id,
                    declaration: declaration,
                    installation: fixture.installation
                )
            }
            try await Self.expectCounts(transfers: 1, attempts: 1, receipts: 0, on: app)
            try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
        }
    }

    @Test
    func expiredBytesCanBeUploadedAgainWithoutRewritingEvidence() async throws {
        try await Self.withFixture { app, fixture, service, declaration in
            let id = UUID()
            let first = try await service.upload(
                HTTPBody(Self.bytes), sourceID: fixture.source.id, transferID: id, declaration: declaration, installation: fixture.installation
            )
            let now = first.expiresAt.addingTimeInterval(1)
            let next = try Self.attempt(await service.reserve(
                sourceID: fixture.source.id, transferID: id, declaration: declaration, installation: fixture.installation, now: now
            ))
            #expect(next.reference.id != first.artifactID)
            let artifacts = ArtifactStore(database: app.db, storage: service.storage)
            try await artifacts.uploadReservedRecording(HTTPBody(Self.bytes), reference: next.reference)
            try await service.complete(
                    next,
                    sourceID: fixture.source.id,
                    transferID: id,
                    declaration: declaration,
                    installation: fixture.installation,
                    now: now
                )
            let recovered = try await service.lookup(sourceID: fixture.source.id, transferID: id)
            #expect(recovered.artifactID == next.reference.id)
            #expect(recovered.declarationSHA256 == first.declarationSHA256)
            try await Self.expectCounts(transfers: 1, attempts: 2, receipts: 2, on: app)
        }
    }
}


extension RecordingTransferTests {
    @Test
    func concurrentReservationsClaimOnlyOneObject() async throws {
        try await Self.withFixture { app, fixture, service, declaration in
            let id = UUID()
            let results = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        do {
                            _ = try await service.reserve(
                                sourceID: fixture.source.id, transferID: id, declaration: declaration, installation: fixture.installation
                            )
                            return true
                        } catch {
                            #expect((error as? TroveServer.ServerError)?.status.code == 409)
                            return false
                        }
                    }
                }
                var results: [Bool] = []
                for await result in group { results.append(result) }
                return results
            }
            #expect(results.filter { $0 }.count == 1)
            try await Self.expectCounts(transfers: 1, attempts: 1, receipts: 0, on: app)
        }
    }

    @Test
    func workoutConsentWithoutRoutesCannotReserveStorage() async throws {
        try await Self.withFixture { app, fixture, service, declaration in
            let noRouteAuthority = try Self.declaration(fixture, at: declaration.output.effectiveAt, studyIndex: 1)
            let input = ObjectStorageStreamSource([String(decoding: Self.bytes, as: UTF8.self)])
            await #expect {
                try await service.upload(
                    input.body(length: .known(Int64(Self.bytes.count))),
                    sourceID: fixture.source.id,
                    transferID: UUID(),
                    declaration: noRouteAuthority,
                    installation: fixture.installation
                )
            } throws: { ($0 as? TroveServer.ServerError)?.status.code == 403 }
            #expect(await input.reads == 0)
            try await Self.expectCounts(transfers: 0, attempts: 0, receipts: 0, on: app)
        }
    }

    @Test
    func failedStreamingReleasesTheAttemptForImmediateRetry() async throws {
        try await Self.withFixture { app, fixture, service, declaration in
            let id = UUID()
            let input = ObjectStorageStreamSource(["synthetic ", "recording"], failureAt: 1)
            await #expect(throws: (any Error).self) {
                try await service.upload(
                    input.body(length: .known(Int64(Self.bytes.count))),
                    sourceID: fixture.source.id,
                    transferID: id,
                    declaration: declaration,
                    installation: fixture.installation
                )
            }
            try await Self.expectCounts(transfers: 1, attempts: 1, receipts: 0, on: app)
            let receipt = try await service.upload(
                HTTPBody(Self.bytes), sourceID: fixture.source.id, transferID: id, declaration: declaration, installation: fixture.installation
            )
            #expect(receipt.storedSHA256 == declaration.content.storedSHA256)
            try await Self.expectCounts(transfers: 1, attempts: 2, receipts: 1, on: app)
        }
    }

    @Test
    func storedDigestMismatchCannotProduceAReceipt() async throws {
        try await Self.withFixture { app, fixture, service, declaration in
            let id = UUID()
            await #expect(throws: (any Error).self) {
                try await service.upload(
                    HTTPBody(Data(repeating: 65, count: Self.bytes.count)),
                    sourceID: fixture.source.id,
                    transferID: id,
                    declaration: declaration,
                    installation: fixture.installation
                )
            }
            try await Self.expectCounts(transfers: 1, attempts: 1, receipts: 0, on: app)
        }
    }

    @Test
    func receiptRecoverySurvivesRestartAndSourceRevocation() async throws {
        try await Self.withFixture { app, fixture, service, declaration in
            let id = UUID()
            let receipt = try await service.upload(
                HTTPBody(Self.bytes), sourceID: fixture.source.id, transferID: id, declaration: declaration, installation: fixture.installation
            )
            _ = try await app.grove[SourceBindingService.self].revoke(id: fixture.source.id)
            try await TestDatabase.withRestartedApplication(app) { restarted in
                let recovered = RecordingTransferService(database: restarted.db, storage: service.storage, limits: service.limits)
                let actual = try await recovered.lookup(sourceID: fixture.source.id, transferID: id)
                #expect(actual == receipt)
            }
        }
    }

    @Test
    func foreignAccountsAndFailedDisclosureAuditCannotReadReceipts() async throws {
        try await Self.withFixture { app, fixture, service, declaration in
            let id = UUID()
            _ = try await service.upload(
                HTTPBody(Self.bytes), sourceID: fixture.source.id, transferID: id, declaration: declaration, installation: fixture.installation
            )
            let original = ClinicalEventStoreTests.participant
            let other = AuthContext(
                issuer: original.issuer,
                subject: "other-participant",
                email: "other@example.invalid",
                roles: original.roles,
                groups: [],
                researcherRole: original.researcherRole,
                participantRole: original.participantRole
            )
            await AuthContext.$current.withValue(other) {
                await #expect(throws: (any Error).self) { try await service.lookup(sourceID: fixture.source.id, transferID: id) }
            }
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("DROP TABLE audit_events").run()
            await #expect(throws: (any Error).self) { try await service.lookup(sourceID: fixture.source.id, transferID: id) }
            try await Self.expectCounts(transfers: 1, attempts: 1, receipts: 1, on: app)
        }
    }

    @Test
    func transferEvidenceCannotBeRewrittenDeletedOrRolledBack() async throws {
        try await Self.withFixture { app, fixture, service, declaration in
            _ = try await service.upload(
                HTTPBody(Self.bytes), sourceID: fixture.source.id, transferID: UUID(), declaration: declaration, installation: fixture.installation
            )
            let sql = try #require(app.db as? any SQLDatabase)
            let columns = [
                ("recording_transfers", "declaration"), ("recording_transfer_attempts", "attempt_number"),
                ("recording_transfer_receipts", "stored_sha256")
            ]
            for (table, column) in columns {
                await #expect(throws: (any Error).self) {
                    try await sql.raw("UPDATE \(ident: table) SET \(ident: column) = \(ident: column)").run()
                }
                await #expect(throws: (any Error).self) { try await sql.raw("DELETE FROM \(ident: table)").run() }
            }
            await #expect(throws: CreateRecordingTransfers.RollbackError.self) { try await CreateRecordingTransfers().revert(on: app.db) }
            try await Self.expectCounts(transfers: 1, attempts: 1, receipts: 1, on: app)
        }
    }
}


extension RecordingTransferTests {
    private typealias Exercise = @Sendable (
        Application, ClinicalEventStoreTests.Fixture, RecordingTransferService, RecordingTransferDeclaration
    ) async throws -> Void

    private static func exerciseInterruptedAttempt(
        _ app: Application,
        fixture: ClinicalEventStoreTests.Fixture,
        service: RecordingTransferService,
        declaration: RecordingTransferDeclaration
    ) async throws {
        let id = UUID(), now = Date()
        let first = try Self.attempt(await service.reserve(
            sourceID: fixture.source.id, transferID: id, declaration: declaration, installation: fixture.installation, now: now
        ))
        let artifacts = ArtifactStore(database: app.db, storage: service.storage)
        let interrupted = ObjectStorageStreamSource(["synthetic ", "recording"], failureAt: 1)
        await #expect(throws: (any Error).self) {
            try await artifacts.uploadReservedRecording(interrupted.body(length: .known(Int64(Self.bytes.count))), reference: first.reference)
        }
        await #expect(throws: (any Error).self) { try await service.lookup(sourceID: fixture.source.id, transferID: id) }
        await #expect {
            try await service.reserve(
                sourceID: fixture.source.id,
                transferID: id,
                declaration: declaration,
                installation: fixture.installation,
                now: now
            )
        } throws: { ($0 as? TroveServer.ServerError)?.status.code == 409 }
        let later = now.addingTimeInterval(service.limits.leaseDuration + 1)
        let second = try Self.attempt(await service.reserve(
            sourceID: fixture.source.id, transferID: id, declaration: declaration, installation: fixture.installation, now: later
        ))
        #expect(second.reference.key != first.reference.key)
        try await artifacts.uploadReservedRecording(HTTPBody(Self.bytes), reference: first.reference)
        await #expect {
            try await service.complete(
                first,
                sourceID: fixture.source.id,
                transferID: id,
                declaration: declaration,
                installation: fixture.installation,
                now: later
            )
        } throws: { ($0 as? TroveServer.ServerError)?.status.code == 409 }
        try await artifacts.uploadReservedRecording(HTTPBody(Self.bytes), reference: second.reference)
        try await service.complete(
                second,
                sourceID: fixture.source.id,
                transferID: id,
                declaration: declaration,
                installation: fixture.installation,
                now: later
            )
        let receipt = try await service.lookup(sourceID: fixture.source.id, transferID: id)
        #expect(receipt.artifactID == second.reference.id)
        try await Self.expectCounts(transfers: 1, attempts: 2, receipts: 1, on: app)
    }

    private static func attempt(_ reservation: RecordingTransferService.Reservation) throws -> RecordingTransferService.Attempt {
        guard case .upload(let attempt) = reservation else {
            throw TroveServer.ServerError.unexpectedError
        }
        return attempt
    }

    private static func declaration(
        _ fixture: ClinicalEventStoreTests.Fixture,
        at date: Date,
        path: String = "recordings/route.csv",
        bytes: Data = Self.bytes,
        studyIndex: Int = 0
    ) throws -> RecordingTransferDeclaration {
        try .init(
            attachmentPath: path,
            outputFullURL: output,
            profile: FHIRRecordingProjection.profile,
            format: .locationTrackSamples,
            effectiveAt: date,
            effectiveEnd: date,
            content: .init(
                storedByteCount: bytes.count,
                storedSHA256: ArtifactStore.digest(bytes),
                sourceByteCount: bytes.count,
                sourceSHA256: ArtifactStore.digest(bytes),
                encoding: .identity
            ),
            targets: [.init(consentID: fixture.consentIDs[studyIndex], outputFullURLs: [output])]
        )
    }

    private static func withFixture(
        _ test: @escaping Exercise
    ) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(
                on: app, profile: CollectionObservationProfile.workout.rawValue, routeStudies: [0]
            )
            let service = RecordingTransferService(
                database: app.db,
                storage: app.grove[ObjectStorageService.self],
                limits: try .init(storedBytes: 1024, sourceBytes: 4096)
            )
            let declaration = try declaration(fixture, at: Date())
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) { try await test(app, fixture, service, declaration) }
        }
    }

    private static func expectCounts(transfers: Int, attempts: Int, receipts: Int, on app: Application) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        let counts = [("recording_transfers", transfers), ("recording_transfer_attempts", attempts), ("recording_transfer_receipts", receipts)]
        for (table, expected) in counts {
            let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM \(ident: table)").first())
            #expect(try row.decode(column: "count", as: Int.self) == expected)
        }
    }
}
