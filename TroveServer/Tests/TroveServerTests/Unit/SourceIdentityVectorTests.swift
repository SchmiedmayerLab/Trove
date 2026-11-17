//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import GroveFHIRContract
import GroveProviderFHIR
import SQLKit
import Testing
import TroveAPITypes
@testable import TroveServer


/// The server hands the participant app its identity context and mints provider records under the same derivation.
/// Both paths must reproduce the vectors that `TroveAPITests.SourceIdentityVectorTests` checks for the app.
struct SourceIdentityVectorTests {
    private struct Identifier: Decodable, Equatable {
        let system: String
        let value: String
    }

    private struct Vectors: Decodable {
        struct Context: Decodable {
            let identifierRoot: String
            let keyID: UUID
            let keyEpoch: String
            let keyHex: String
            let repositoryKind: String
            let repositoryScope: Identifier
            let participantIdentifier: Identifier
        }

        struct Output: Decodable {
            let role: String
            let discriminator: String
            let identifier: Identifier
        }

        struct SourceRecord: Decodable {
            let adapterID: String
            let sourceType: String
            let repositoryScope: Identifier
            let nativeRecordID: String
            let sourceRecord: Identifier
            let outputs: [Output]
        }

        struct ProviderRecord: Decodable {
            let provider: String
            let sourceType: String
            let providerScope: Identifier
            let scope: String
            let nativeRecordID: String
            let providerRecord: Identifier
        }

        let context: Context
        let systems: [String: String]
        let nativeRecordIdentifierSystem: String
        let sourceRecords: [SourceRecord]
        let providerRecords: [ProviderRecord]
    }

    /// Persisted source rows are the only way a binding is constructed; this row carries the vector's assignment.
    private struct Row: SQLRow {
        let values: [String: any Sendable]

        var allColumns: [String] { Array(values.keys) }

        func contains(column: String) -> Bool { values[column] != nil }

        func decodeNil(column: String) throws -> Bool {
            guard let value = values[column] else {
                return true
            }
            let mirror = Mirror(reflecting: value)
            return mirror.displayStyle == .optional && mirror.children.isEmpty
        }

        func decode<D: Decodable>(column: String, as type: D.Type) throws -> D {
            try #require(values[column] as? D, "Unexpected \(column)")
        }
    }

    private static func vectors() throws -> Vectors {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("TroveAPI/Tests/TroveAPITests/Fixtures/source-identity-vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    private static func binding(
        _ context: Vectors.Context, kind: SourceKind, repositoryKind: SourceRepositoryKind
    ) throws -> SourceBinding {
        let sourceID = try #require(UUID(uuidString: String(context.identifierRoot.split(separator: "/").last ?? "")))
        let values: [String: any Sendable] = [
            "id": sourceID, "participant_id": UUID(), "key_id": context.keyID, "key_epoch": context.keyEpoch,
            "repository_kind": repositoryKind, "kind": kind,
            "provider_registration_id": kind == .serverWorker ? UUID() as UUID? : nil as UUID?,
            "event_identifier_system": "\(context.identifierRoot)/NamingSystem/grove-record-version-v0/"
                + "\(context.keyID.uuidString.lowercased())/\(context.keyEpoch)",
            "identifier_root": context.identifierRoot,
            "participant_identifier_system": context.participantIdentifier.system,
            "participant_identifier_value": context.participantIdentifier.value,
            "created_at": Date(timeIntervalSince1970: 1_700_000_000), "revoked_at": nil as Date?
        ]
        return try SourceBinding(row: Row(values: values))
    }

    private static func recovered(_ context: Vectors.Context, source: SourceBinding) throws -> SourceIdentityKeyStore.Recovered {
        let key = Data(stride(from: 0, to: context.keyHex.count, by: 2).compactMap { offset in
            let start = context.keyHex.index(context.keyHex.startIndex, offsetBy: offset)
            return UInt8(context.keyHex[start..<context.keyHex.index(start, offsetBy: 2)], radix: 16)
        })
        try #require(key.count == 32)
        return .init(
            context: try .init(
                owner: (source.participantID, source.id),
                keyID: source.keyID,
                epoch: source.keyEpoch,
                identifierRoot: source.identifierRoot,
                repository: BusinessIdentifier(system: IdentifierSystem(source.identifierRoot + "/repository"), value: source.repositoryKind.rawValue)
            ),
            key: SymmetricKey(data: key)
        )
    }

    private static func systems(_ systems: DeploymentIdentifierSystems) -> [String: String] {
        [
            "sourceRecord": systems.sourceRecord, "sourceOutput": systems.sourceOutput, "writerRecord": systems.writerRecord,
            "providerRecord": systems.providerRecord, "providerOutput": systems.providerOutput,
            "sourceArtifact": systems.sourceArtifact, "providerArtifact": systems.providerArtifact,
            "sourceContext": systems.sourceContext, "recordingDevice": systems.recordingDevice,
            "deviceSnapshot": systems.deviceSnapshot, "contextSnapshot": systems.contextSnapshot,
            "recordVersion": systems.recordVersion, "recordRetraction": systems.recordRetraction
        ].mapValues(\.rawValue)
    }

    private static func identifier(_ value: BusinessIdentifier) -> Identifier {
        .init(system: value.system.rawValue, value: value.value)
    }

    @Test
    func assignedParticipantSourceAndServerScopeReproduceTheSharedVectors() throws {
        let vectors = try Self.vectors()
        let source = try Self.binding(vectors.context, kind: .participantApp, repositoryKind: .healthKit)
        #expect(Self.systems(try SourceIdentityNamespaces.assign(root: source.identifierRoot, keyID: source.keyID, epoch: source.keyEpoch))
            == vectors.systems)
        // The registration the participant app recovers from this server.
        let assigned = try Components.Schemas.ParticipantSource(source)
        #expect(assigned.keyID == vectors.context.keyID.uuidString.lowercased() && assigned.keyEpoch == vectors.context.keyEpoch)
        #expect(assigned.repositoryKind.rawValue == vectors.context.repositoryKind)
        #expect(Identifier(system: assigned.repositoryScope.system, value: assigned.repositoryScope.value) == vectors.context.repositoryScope)
        #expect(Self.systems(try assigned.identifierSystems()) == vectors.systems)
        #expect(try assigned.nativeRecordIdentifierSystem().rawValue == vectors.nativeRecordIdentifierSystem)

        let scope = try ProviderAcquisitionFacts.identityScope(source: source, identity: Self.recovered(vectors.context, source: source))
        #expect(Self.systems(scope.systems) == vectors.systems)
        for vector in vectors.sourceRecords {
            let record = try scope.sourceRecord(
                adapterID: vector.adapterID,
                sourceType: vector.sourceType,
                repositoryScope: BusinessIdentifier(system: IdentifierSystem(vector.repositoryScope.system), value: vector.repositoryScope.value),
                nativeRecordID: vector.nativeRecordID
            )
            #expect(Self.identifier(record.identifier.identifier) == vector.sourceRecord)
            for output in vector.outputs {
                #expect(Self.identifier(try record.output(role: output.role, discriminator: output.discriminator).identifier) == output.identifier)
            }
        }
    }

    @Test
    func providerWorkerRecordsReproduceTheSharedVectors() throws {
        let vectors = try Self.vectors()
        let source = try Self.binding(vectors.context, kind: .serverWorker, repositoryKind: .oura)
        let facts = ProviderAcquisitionFacts(
            application: try .init(name: "Trove", bundleIdentifier: "org.example.Trove", version: "1"),
            host: try .init(operatingSystemName: "Linux", operatingSystemVersion: "6")
        )
        let producer = try facts.producer(source: source, identity: Self.recovered(vectors.context, source: source))
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        for vector in vectors.providerRecords {
            #expect(vector.provider == "oura" && vector.scope == "global")
            let scope = try BusinessIdentifier(system: IdentifierSystem(vector.providerScope.system), value: vector.providerScope.value)
            let context = ProviderConversionContext(
                producer: producer, scope: .global(scope), instant: timestamp.addingTimeInterval(60), sourceTimeZone: .gmt
            )
            let identity = try context.sourceIdentity(provider: .oura, sourceType: vector.sourceType, nativeRecordID: vector.nativeRecordID)
            #expect(Self.identifier(identity.identifier.identifier) == vector.providerRecord)
            let record = try #require(OuraFHIR.convert(.vo2Max(id: vector.nativeRecordID, timestamp: timestamp, value: 45), context: context).record)
            #expect(Self.identifier(record.sourceRecord) == vector.providerRecord)
        }
    }
}
