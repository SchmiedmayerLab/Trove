//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveSensorKitFHIR
import Testing
import TroveAPIClient
@testable import TroveSensorKit


struct SensorKitJournalFixture {
    enum Failure: Error { case interrupted }
    let sourceID = UUID()
    let localID = UUID()
    let enrollmentID = UUID()
    let consentID = UUID()
    let recordID = UUID()
    let instant = Date.now.addingTimeInterval(-60)
    let scope = EventDeliveryJournal.Scope(backend: "https://trove.test", issuer: "https://identity.test", subject: "sensor-participant")

    func withJournal(
        limits: EventDeliveryJournal.Limits = .init(),
        sourceToken: String? = nil,
        collectionSnapshot: ParticipantCollectionSnapshot? = nil,
        operation: (EventDeliveryJournal, URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        var protected = directory
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try protected.setResourceValues(resources)
        #endif
        let url = directory.appendingPathComponent("delivery.sqlite")
        let journal = try EventDeliveryJournal(url: url, scope: scope, mode: .createNew, limits: limits)
        do {
            let query = try SensorKitQueryDefinition(sourceToken: sourceToken ?? token(), deviceProductType: "Watch1,1")
            let setup = try await journal.createSource(localID: localID, queryDefinition: query.encoded())
            try await journal.confirmSource(binding(), for: setup, identityKey: Data(repeating: 0x42, count: 32))
            let state = try await journal.collectionState()
            try await journal.retainCollectionSnapshot(collectionSnapshot ?? snapshot(), replacing: state)
            try await operation(journal, url)
        } catch {
            await journal.close()
            throw error
        }
        await journal.close()
    }

    func batch(
        valid: Bool = true,
        acknowledge: @escaping @Sendable () async throws -> Void = {}
    ) throws -> SensorKitAcquisition.Batch {
        let sourceID = SensorKitSourceRecordID(recordID)
        let record = SensorKitOnWristRecord(
            sourceRecordID: sourceID,
            timestamp: instant,
            onWrist: true,
            currentStateStart: instant.addingTimeInterval(valid ? -30 : 30),
            wristLocation: .left,
            crownOrientation: .right
        )
        return try .init(
            coordinate: "durable-batch-one",
            sourceToken: token(),
            deviceProductType: "Watch1,1",
            inputs: [
                .init(
                    sourceID: sourceID,
                    sourceToken: token(),
                    profile: .onWrist,
                    record: .onWrist(record),
                    digest: Data(repeating: 1, count: 32),
                    start: instant,
                    end: nil
                )
            ],
            facts: SensorKitBatchSnapshot(
                application: ApplicationDevice(name: "Test", bundleIdentifier: "org.example.test", version: "1", build: "1"),
                host: HostDevice(operatingSystemName: "iOS", operatingSystemVersion: "27.2"),
                recordingDevice: nil,
                sourceTimeZone: #require(TimeZone(secondsFromGMT: 0)),
                conversionInstant: instant
            ),
            acknowledge: acknowledge
        )
    }

    private func token() throws -> String {
        try #require(SensorKitCatalog.current.entries.first { $0.structuredContract == .onWrist }).sourceToken
    }

    private func binding() -> Components.Schemas.ParticipantSourceRegistration {
        let root = "https://trove.test/sources/" + sourceID.uuidString.lowercased()
        return .init(
            source: .init(
                id: sourceID.uuidString.lowercased(),
                keyID: localID.uuidString.lowercased(),
                keyEpoch: "1",
                repositoryKind: .sensorkit,
                repositoryScope: .init(system: root + "/repository", value: "sensorkit"),
                kind: .participantApp,
                eventIdentifierSystem: root + "/NamingSystem/grove-record-version-v0/\(localID.uuidString.lowercased())/1",
                identifierRoot: root,
                participantIdentifier: .init(system: scope.issuer + "/trove/participants", value: consentID.uuidString.lowercased()),
                createdAt: instant
            ),
            installation: .init(registrationID: localID.uuidString.lowercased(), sourceID: sourceID.uuidString.lowercased(), createdAt: instant)
        )
    }

    private func snapshot() throws -> ParticipantCollectionSnapshot {
        let start = instant.addingTimeInterval(-3600)
        let plan = Components.Schemas.ParticipantCollectionPlan(
            enrollmentId: enrollmentID.uuidString.lowercased(),
            studyId: UUID().uuidString.lowercased(),
            title: .init([.enUS: "Sensor study"]),
            stateVersion: 1,
            asOf: instant,
            windows: [
                .init(
                    consentId: consentID.uuidString.lowercased(),
                    publicationId: UUID().uuidString.lowercased(),
                    revision: 1,
                    start: start,
                    requirements: [
                        .init(
                            profile: CollectionObservationProfile.onWrist.rawValue,
                            sourceTypeIdentifier: try token(),
                            sourceKind: .participantApp,
                            start: start
                        )
                    ]
                )
            ]
        )
        return try ParticipantCollectionSnapshot(plans: [plan], enrollmentIDs: [enrollmentID])
    }
}
