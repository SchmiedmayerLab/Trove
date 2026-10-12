//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIClient


enum DeliveryFixture {
    static let sourceID = UUID()
    static let consentID = UUID()
    static let epoch = UUID()
    static let queryDefinition = Data("synthetic-query-v1".utf8)
    static let scope = EventDeliveryJournal.Scope(backend: "https://trove.test", issuer: "https://identity.test", subject: "participant-a")

    static func withJournal(
        limits: EventDeliveryJournal.Limits = .init(),
        _ operation: (EventDeliveryJournal, URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("trove-delivery-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        #if os(iOS) || os(watchOS) || os(visionOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        var protectedDirectory = directory
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(resources)
        #endif
        let url = directory.appendingPathComponent("delivery.sqlite")
        let journal = try EventDeliveryJournal(url: url, scope: scope, mode: .createNew, limits: limits)
        do {
            try await register(journal, sourceID: sourceID, query: queryDefinition, localID: epoch)
            try await operation(journal, url)
        } catch {
            await journal.close()
            throw error
        }
        await journal.close()
    }

    static func stage(_ journal: EventDeliveryJournal, changes: [String]) async throws -> [UUID] {
        let checkpoint = try await journal.checkpoint(for: sourceID)
        return try await journal.stage(
            from: checkpoint,
            nextCursor: Data(UUID().uuidString.utf8),
            payloads: [payload(sequence: 1, changes: changes, producerID: UUID())]
        )
    }

    static func register(_ journal: EventDeliveryJournal, sourceID: UUID, query: Data, localID: UUID = UUID()) async throws {
        let setup = try await journal.createSource(localID: localID, queryDefinition: query)
        try await journal.confirmSource(binding(sourceID: sourceID, registrationID: localID), for: setup)
    }

    static func binding(sourceID: UUID, registrationID: UUID) -> Components.Schemas.ParticipantSource {
        .init(
            id: sourceID.uuidString.lowercased(),
            registrationID: registrationID.uuidString.lowercased(),
            kind: .participantApp,
            eventIdentifierSystem: identifierRoot(sourceID) + "/NamingSystem/grove-event-v0",
            identifierRoot: identifierRoot(sourceID),
            participantIdentifier: .init(system: scope.issuer + "/trove/participants", value: consentID.uuidString.lowercased()),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    static func unexpectedBuild(_ index: Int, _ sequence: Int64) throws -> EventDeliveryJournal.Payload {
        throw EventDeliveryJournal.JournalError.invalidConfiguration
    }

    static func payload(
        sequence: Int64, changes: [String], sourceID: UUID = DeliveryFixture.sourceID, producerID: UUID? = nil
    ) -> EventDeliveryJournal.Payload {
        // These are commitment envelopes, not claimed FHIR-conformant clinical fixtures.
        let entries = Array(repeating: "{}", count: changes.count).joined(separator: ",")
        let bytes = Data("""
            {"identifier":{"system":"\(identifierRoot(sourceID))/NamingSystem/grove-event-v0","value":"e0:\((producerID ?? sourceID).uuidString.lowercased()):\(sequence)"},"entry":[\(entries)]}
            """.utf8)
        return .init(bytes: bytes, targets: [.init(consentID: consentID, outputFullURLs: ["urn:output:a"])])
    }

    static func identifierRoot(_ sourceID: UUID) -> String {
        "https://trove.test/sources/" + sourceID.uuidString.lowercased()
    }

    static func receipt(_ attempt: EventDeliveryJournal.Attempt) -> Components.Schemas.EventReceipt {
        .init(
            eventId: UUID().uuidString,
            sourceId: sourceID.uuidString.lowercased(),
            producerEventIdentifier: attempt.commitment.producerEventIdentifier,
            payloadSHA256: attempt.commitment.payloadSHA256,
            targetIntentSHA256: attempt.commitment.targetIntent.sha256,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            nodeCount: attempt.commitment.nodeCount
        )
    }
}
