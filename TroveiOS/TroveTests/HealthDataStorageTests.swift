//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveLocalization
import Testing
@testable import Trove
import TroveAPIClient


struct HealthDataStorageTests {
    private static let scope = EventDeliveryJournal.Scope(backend: "https://api.example", issuer: "https://identity.example", subject: "participant")

    @Test
    func scopePathsAreStableOpaqueAndAccountSpecific() throws {
        let root = URL.temporaryDirectory
        let path = try HealthDataStorage.directory(for: Self.scope, root: root)
        #expect(try HealthDataStorage.directory(for: Self.scope, root: root) == path)
        #expect(!path.lastPathComponent.contains(Self.scope.subject))
        let other = EventDeliveryJournal.Scope(backend: Self.scope.backend, issuer: Self.scope.issuer, subject: "other")
        #expect(try HealthDataStorage.directory(for: other, root: root) != path)
    }

    @Test
    func creationAndRestorationKeepTheSameSourceAndPrivateStorage() async throws {
        let root = URL.temporaryDirectory.appending(path: "health-delivery-test-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await HealthDataStorage.open(scope: Self.scope, root: root, create: false) == nil)
        let opened = try await HealthDataStorage.open(scope: Self.scope, root: root, create: true)
        let journal = try #require(opened)
        let source = try await journal.createSource(localID: UUID(), queryDefinition: Data([1]))
        await journal.close()
        let restored = try await HealthDataStorage.open(scope: Self.scope, root: root, create: true)
        let reopened = try #require(restored)
        #expect(try await reopened.sourceSetups() == [source])
        await reopened.close()
        let directory = try HealthDataStorage.directory(for: Self.scope, root: root)
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test
    func withdrawalBeforeDeviceSetupSurvivesRestartWithoutCreatingASource() async throws {
        let root = URL.temporaryDirectory.appending(path: "health-withdrawal-test-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let enrollmentID = UUID()
        try await HealthDataStorage.stopCollection(for: enrollmentID, scope: Self.scope, root: root)
        let opened = try await HealthDataStorage.open(scope: Self.scope, root: root, create: false)
        let journal = try #require(opened)
        let state = try await journal.collectionState()
        #expect(state.stoppedEnrollmentIDs == [enrollmentID])
        #expect(state.snapshot == nil)
        #expect(try await journal.sourceSetups().isEmpty)
        await journal.close()
        let other = EventDeliveryJournal.Scope(backend: Self.scope.backend, issuer: Self.scope.issuer, subject: "other")
        #expect(try await HealthDataStorage.open(scope: other, root: root, create: false) == nil)
    }

    @Test
    func savedDetailsAreReadLocallyAndRemainScopedAfterWithdrawal() async throws {
        let root = URL.temporaryDirectory.appending(path: "health-settings-test-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await HealthDataStorage.collections(scope: Self.scope, root: root).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let opened = try await HealthDataStorage.open(scope: Self.scope, root: root, create: true)
        let journal = try #require(opened)
        let id = UUID()
        let plan = Components.Schemas.ParticipantCollectionPlan(
            enrollmentId: id.uuidString,
            studyId: UUID().uuidString,
            title: .init([.enUS: "Saved Study"]),
            stateVersion: 1,
            asOf: Date(timeIntervalSince1970: 1),
            windows: []
        )
        let snapshot = try ParticipantCollectionSnapshot(plans: [plan], enrollmentIDs: [id])
        try await journal.retainCollectionSnapshot(snapshot, replacing: journal.collectionState())
        await journal.close()
        try await HealthDataStorage.stopCollection(for: id, scope: Self.scope, root: root)
        let restored = try await HealthDataStorage.collections(scope: Self.scope, root: root)
        #expect(restored.map(\.plan) == [plan])
        #expect(restored.first?.isStopped == true)
        let other = EventDeliveryJournal.Scope(backend: Self.scope.backend, issuer: Self.scope.issuer, subject: "other")
        #expect(try await HealthDataStorage.collections(scope: other, root: root).isEmpty)
    }

    @Test
    func restorationRejectsStorageThatIsNoLongerPrivate() async throws {
        let root = URL.temporaryDirectory.appending(path: "health-delivery-test-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let opened = try await HealthDataStorage.open(scope: Self.scope, root: root, create: true)
        let journal = try #require(opened)
        await journal.close()
        let directory = try HealthDataStorage.directory(for: Self.scope, root: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        await #expect(throws: EventDeliveryJournal.JournalError.unsafeStorage) {
            try await HealthDataStorage.open(scope: Self.scope, root: root, create: false)
        }
    }

    @Test
    func restorationRequiresBackupExclusion() async throws {
        let root = URL.temporaryDirectory.appending(path: "health-delivery-test-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let opened = try await HealthDataStorage.open(scope: Self.scope, root: root, create: true)
        let journal = try #require(opened)
        await journal.close()
        var directory = try HealthDataStorage.directory(for: Self.scope, root: root)
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try directory.setResourceValues(values)
        await #expect(throws: EventDeliveryJournal.JournalError.invalidConfiguration) {
            try await HealthDataStorage.open(scope: Self.scope, root: root, create: false)
        }
    }

    @Test
    func missingDatabaseInAnEstablishedDirectoryIsNeverRecreated() async throws {
        let root = URL.temporaryDirectory.appending(path: "health-delivery-test-\(UUID())", directoryHint: .isDirectory)
        let directory = try HealthDataStorage.directory(for: Self.scope, root: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) {
            try await HealthDataStorage.open(scope: Self.scope, root: root, create: true)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "delivery.sqlite").path))
    }
}
