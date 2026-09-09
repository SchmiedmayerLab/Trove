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
@testable import TroveServer


private actor ArtifactStorage: ObjectStorageProvider {
    private var objects: [String: Data] = [:]
    private var beforeUpload: (@Sendable () async throws -> Void)?
    private(set) var deleted: [String] = []
    private var failDeletion = false

    func interceptUpload(_ action: @escaping @Sendable () async throws -> Void) { beforeUpload = action }
    func failDeletes(_ value: Bool) { failDeletion = value }
    func contains(_ key: String) -> Bool { objects[key] != nil }

    func upload(data: Data, key: String, contentType: String) async throws {
        let action = beforeUpload
        beforeUpload = nil
        try await action?()
        objects[key] = data
    }

    func download(key: String, maximumBytes: Int) throws -> Data {
        guard let data = objects[key] else { throw ServerError.notFound("Synthetic artifact missing") }
        return data
    }

    func delete(key: String) throws {
        if failDeletion { throw ServerError.internalServerError("Synthetic deletion failure") }
        objects.removeValue(forKey: key)
        deleted.append(key)
    }

    func ensureBucketExists() {}
    func shutdown() {}
}


struct ArtifactLifecycleTests {
    private enum Rejected: Error { case transaction }
    private static let bytes = Data("%PDF-1.4 synthetic artifact".utf8)
    private static let owner = UUID()
    private static let scope = StudyArtifactScope(studyID: UUID())

    @Test
    func acceptanceAndCleanupHaveDistinctDurableStates() async throws {
        let provider = ArtifactStorage()
        try await TestApp.withApp(storageProvider: provider) { app, _ in
            let store = ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self])
            let reference = try await store.stage(Self.bytes, purpose: .consent, ownerID: Self.owner, scope: Self.scope)
            #expect(try await StoredArtifact.find(reference.id, on: app.db)?.state == .ready)
            await #expect(throws: (any Error).self) {
                try await store.download(id: reference.id, ownerID: Self.owner, purpose: .consent, expected: (reference.key, reference.digest))
            }
            try await app.db.transaction { transaction in try await store.retain(reference, on: transaction) }
            let report = try await store.cleanup(now: Date().addingTimeInterval(7200))
            #expect(report.deleted == 0)
            #expect(await provider.deleted.isEmpty)
            #expect(try await StoredArtifact.find(reference.id, on: app.db)?.state == .retained)
            let bytes = try await store.download(
                id: reference.id, ownerID: Self.owner, purpose: .consent, expected: (reference.key, reference.digest)
            )
            #expect(bytes == Self.bytes)
        }
    }

    @Test
    func rollbackLeavesRecoverableUnacceptedStaging() async throws {
        let provider = ArtifactStorage()
        try await TestApp.withApp(storageProvider: provider) { app, _ in
            let store = ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self])
            let reference = try await store.stage(Self.bytes, purpose: .consent, ownerID: Self.owner, scope: Self.scope)
            await #expect(throws: Rejected.transaction) {
                try await app.db.transaction { transaction in
                    try await store.retain(reference, on: transaction)
                    throw Rejected.transaction
                }
            }
            #expect(try await StoredArtifact.find(reference.id, on: app.db)?.state == .ready)
            let report = try await store.cleanup(now: Date().addingTimeInterval(7200))
            #expect(report.deleted == 1)
            #expect(await !provider.contains(reference.key))
            #expect(try await StoredArtifact.find(reference.id, on: app.db)?.state == .discarding)
        }
    }

    @Test
    func lateUploadCannotBeAcceptedAndIsDeletedOnTheNextSweep() async throws {
        let provider = ArtifactStorage()
        try await TestApp.withApp(storageProvider: provider) { app, _ in
            let store = ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self])
            let started = Date()
            await provider.interceptUpload {
                let report = try await store.cleanup(now: started.addingTimeInterval(7200))
                #expect(report.deleted == 1)
            }
            await #expect(throws: (any Error).self) {
                try await store.stage(Self.bytes, purpose: .consent, ownerID: Self.owner, scope: Self.scope, now: started)
            }
            let record = try #require(try await StoredArtifact.query(on: app.db).first())
            let reference = try record.reference()
            #expect(record.state == .discarding)
            #expect(await provider.contains(reference.key))
            await #expect(throws: (any Error).self) {
                try await app.db.transaction { transaction in try await store.retain(reference, on: transaction) }
            }
            let report = try await store.cleanup(now: started.addingTimeInterval(14400))
            #expect(report.deleted == 1)
            #expect(await !provider.contains(reference.key))
            #expect(try await StoredArtifact.query(on: app.db).count() == 1)
        }
    }

    @Test
    func deletionFailureKeepsItsRecoveryLocator() async throws {
        let provider = ArtifactStorage()
        try await TestApp.withApp(storageProvider: provider) { app, _ in
            let store = ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self])
            let reference = try await store.stage(Self.bytes, purpose: .consent, ownerID: Self.owner, scope: Self.scope)
            let due = Date().addingTimeInterval(7200)
            await provider.failDeletes(true)
            let failed = try await store.cleanup(now: due)
            #expect(failed.failed == 1)
            #expect(failed.deleted == 0)
            #expect(await provider.contains(reference.key))
            await provider.failDeletes(false)
            let retried = try await store.cleanup(now: due.addingTimeInterval(7200))
            #expect(retried.deleted == 1)
            #expect(await !provider.contains(reference.key))
        }
    }

    @Test
    func auditFailurePreventsCleanupAndItsFence() async throws {
        let provider = ArtifactStorage()
        try await TestApp.withApp(storageProvider: provider) { app, _ in
            let store = ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self])
            let reference = try await store.stage(Self.bytes, purpose: .consent, ownerID: Self.owner, scope: Self.scope)
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("DROP TABLE audit_events").run()
            await #expect(throws: (any Error).self) { try await store.cleanup(now: Date().addingTimeInterval(7200)) }
            #expect(try await StoredArtifact.find(reference.id, on: app.db)?.state == .ready)
            #expect(await provider.deleted.isEmpty)
        }
    }

    @Test(arguments: [0, 101])
    func invalidBatchLimitDoesNotReachStorage(limit: Int) async throws {
        let provider = ArtifactStorage()
        try await TestApp.withApp(storageProvider: provider) { app, _ in
            let store = ArtifactStore(database: app.db, storage: app.grove[ObjectStorageService.self])
            await #expect(throws: (any Error).self) { try await store.cleanup(limit: limit) }
            #expect(await provider.deleted.isEmpty)
        }
    }
}
