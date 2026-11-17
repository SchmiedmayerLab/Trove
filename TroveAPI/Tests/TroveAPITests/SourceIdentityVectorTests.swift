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
@testable import TroveAPIClient


/// The participant app recovers the server-assigned identity through its journal and must reproduce the shared vectors.
/// `TroveServerTests.SourceIdentityVectorTests` checks the server's provider path against the same file.
struct SourceIdentityVectorTests {
    private static func vectors() throws -> SourceIdentityVectors {
        try .load(from: #require(Bundle.module.url(forResource: SourceIdentityVectors.fileName, withExtension: "json")))
    }

    private static func registration(_ context: SourceIdentityVectors.Context, localID: UUID) -> Components.Schemas.ParticipantSourceRegistration {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        return .init(
            source: .init(
                id: context.sourceID,
                keyID: context.keyID,
                keyEpoch: context.keyEpoch,
                repositoryKind: .init(rawValue: context.repositoryKind) ?? .healthkit,
                repositoryScope: .init(system: context.repositoryScope.system, value: context.repositoryScope.value),
                kind: .participantApp,
                eventIdentifierSystem: "\(context.identifierRoot)/NamingSystem/grove-record-version-v0/\(context.keyID)/\(context.keyEpoch)",
                identifierRoot: context.identifierRoot,
                participantIdentifier: .init(system: context.participantIdentifier.system, value: context.participantIdentifier.value),
                createdAt: createdAt
            ),
            installation: .init(registrationID: localID.uuidString.lowercased(), sourceID: context.sourceID, createdAt: createdAt)
        )
    }

    static func systems(_ systems: DeploymentIdentifierSystems) -> [String: String] {
        [
            "sourceRecord": systems.sourceRecord, "sourceOutput": systems.sourceOutput, "writerRecord": systems.writerRecord,
            "providerRecord": systems.providerRecord, "providerOutput": systems.providerOutput,
            "sourceArtifact": systems.sourceArtifact, "providerArtifact": systems.providerArtifact,
            "sourceContext": systems.sourceContext, "recordingDevice": systems.recordingDevice,
            "deviceSnapshot": systems.deviceSnapshot, "contextSnapshot": systems.contextSnapshot,
            "recordVersion": systems.recordVersion, "recordRetraction": systems.recordRetraction
        ].mapValues(\.rawValue)
    }

    @Test
    func recoveredInstallationsReproduceTheSharedVectors() async throws {
        let vectors = try Self.vectors()
        let context = vectors.context
        let source = Self.registration(context, localID: UUID()).source
        #expect(Self.systems(try source.identifierSystems()) == vectors.systems)
        #expect(try source.nativeRecordIdentifierSystem().rawValue == vectors.nativeRecordIdentifierSystem)
        #expect(source.eventIdentifierSystem == vectors.systems["recordVersion"])

        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("trove-identity-vectors-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let issuer = String(context.participantIdentifier.system.dropLast("/trove/participants".count))
        let scope = EventDeliveryJournal.Scope(backend: "https://trove.test", issuer: issuer, subject: "participant-vectors")
        // A reinstall or second device recovers the same server identity with its own installation credential.
        for installation in ["first", "second"] {
            let journal = try EventDeliveryJournal(url: directory.appendingPathComponent("\(installation).sqlite"), scope: scope, mode: .createNew)
            do {
                let pending = try await journal.createSource(localID: UUID(), queryDefinition: Data(installation.utf8))
                try await journal.confirmSource(Self.registration(context, localID: pending.localID), for: pending, identityKey: context.key)
                let identity = try await journal.identityScope(for: #require(UUID(uuidString: context.sourceID)))
                #expect(Self.systems(identity.systems) == vectors.systems)
                for vector in vectors.sourceRecords {
                    let record = try identity.sourceRecord(
                        adapterID: vector.adapterID,
                        sourceType: vector.sourceType,
                        repositoryScope: BusinessIdentifier(
                            system: IdentifierSystem(vector.repositoryScope.system), value: vector.repositoryScope.value
                        ),
                        nativeRecordID: vector.nativeRecordID
                    )
                    #expect(Self.identifier(record.identifier) == vector.sourceRecord)
                    for output in vector.outputs {
                        #expect(Self.identifier(try record.output(role: output.role, discriminator: output.discriminator)) == output.identifier)
                    }
                }
            } catch {
                await journal.close()
                throw error
            }
            await journal.close()
        }
        #expect(Set(vectors.sourceRecords.map(\.sourceRecord.value)).count == vectors.sourceRecords.count)
    }

    private static func identifier(_ value: RoledIdentifier) -> SourceIdentityVectors.Identifier {
        .init(system: value.identifier.system.rawValue, value: value.identifier.value)
    }
}
