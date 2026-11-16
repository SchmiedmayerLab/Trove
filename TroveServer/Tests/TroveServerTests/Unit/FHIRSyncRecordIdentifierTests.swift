//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import ModelsR4
import Testing
@testable import TroveServer


struct FHIRSyncRecordIdentifierTests {
    @Test(arguments: ["sync-identifier-disclosure", "heartbeat-series-sync-identifier-disclosure"])
    func groveGoldenRecordsStateTheMirroredContract(name: String) throws {
        let bundle = try JSONDecoder().decode(ModelsR4.Bundle.self, from: SyncIdentifierFixture.bytes(name))
        let identifiers = (bundle.entry ?? []).flatMap { entry -> [Identifier] in
            switch entry.resource {
            case .observation(let observation): observation.identifier ?? []
            case .documentReference(let document): document.identifier ?? []
            case .device(let device): device.identifier ?? []
            default: []
            }
        }
        let sync = identifiers.filter(FHIRSyncRecordIdentifier.isTyped)
        #expect(sync.count == 1)
        #expect(sync.first?.system?.value?.url.absoluteString == SyncIdentifierFixture.system)
        #expect(sync.first?.value?.value?.string == SyncIdentifierFixture.value)
    }

    @Test
    func observationSyncIdentifierIsRetainedVerbatimWithoutChangingIdentity() throws {
        let verbatim = "Sync-ABC:01/\u{00E9}"
        let bytes = try SyncIdentifierFixture.changingSyncIdentifier(SyncIdentifierFixture.bytes()) { $0["value"] = verbatim }
        let without = try SyncIdentifierFixture.changing(bytes) { resource in
            resource["identifier"] = (resource["identifier"] as? [[String: Any]])?.filter { !SyncIdentifierFixture.isSyncIdentifier($0) }
        }
        let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-only")
        let base = try FHIRPointProjection.project(validatedBytes: without, validatorIdentity: "test-only")
        #expect(event.rawBytes == bytes)
        #expect(event.syncRecordIdentifiers == [.init(system: SyncIdentifierFixture.system, value: verbatim)])
        #expect(base.syncRecordIdentifiers.isEmpty)
        #expect(event.nativeRecordIdentifiers == base.nativeRecordIdentifiers && event.nativeRecordIdentifiers.count == 1)
        #expect(event.eventIdentifierSystem == base.eventIdentifierSystem && event.eventIdentifierValue == base.eventIdentifierValue)
        #expect(event.deploymentIdentifiers.systems == base.deploymentIdentifiers.systems)
        #expect(event.nodes.map(\.fullURL) == base.nodes.map(\.fullURL))
        #expect(event.outputs.map(\.sourceRecordIdentifier) == base.outputs.map(\.sourceRecordIdentifier))
        #expect(event.outputs.map(\.sourceOutputIdentifier) == base.outputs.map(\.sourceOutputIdentifier))
        #expect(event.outputs.map(\.writerIdentifier) == base.outputs.map(\.writerIdentifier))
        #expect(event.outputs.map(\.writerVersion) == base.outputs.map(\.writerVersion))
    }

    /// Trove roots every native system under the server's issuer URL, which may carry a port and a path.
    @Test
    func syncIdentifierExtendsAnyNativeSystemThatNamesAnAuthority() throws {
        let native = "http://localhost:8080/realms/trove/trove/sources/19e5294b-859b-4670-8c58-9f34f5417cd1/native-healthkit-record"
        let text = String(decoding: try SyncIdentifierFixture.bytes(), as: UTF8.self)
            .replacingOccurrences(of: SyncIdentifierFixture.nativeSystem, with: native)
        let event = try FHIRPointProjection.project(validatedBytes: Data(text.utf8), validatorIdentity: "test-only")
        #expect(event.syncRecordIdentifiers == [
            .init(system: native + "/healthkit-sync-identifier/org.example.writer", value: SyncIdentifierFixture.value)
        ])
        #expect(event.nativeRecordIdentifiers.map(\.system) == [native])
    }

    @Test
    func documentPrimaryAdmitsTheSyncIdentifierExactlyAsAnObservation() throws {
        let name = "heartbeat-series-sync-identifier-disclosure"
        let bytes = try SyncIdentifierFixture.bytes(name)
        let without = try SyncIdentifierFixture.changing(bytes, resourceType: "DocumentReference") { resource in
            resource["identifier"] = (resource["identifier"] as? [[String: Any]])?.filter { !SyncIdentifierFixture.isSyncIdentifier($0) }
        }
        let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-only")
        let base = try FHIRPointProjection.project(validatedBytes: without, validatorIdentity: "test-only")
        #expect(event.syncRecordIdentifiers == [.init(system: SyncIdentifierFixture.system, value: SyncIdentifierFixture.value)])
        #expect(event.nativeRecordIdentifiers == base.nativeRecordIdentifiers && event.nativeRecordIdentifiers.count == 1)
        #expect(event.deploymentIdentifiers.systems == base.deploymentIdentifiers.systems)
        #expect(event.outputs.map(\.sourceRecordIdentifier) == base.outputs.map(\.sourceRecordIdentifier))
        #expect(event.outputs.map(\.writerIdentifier) == base.outputs.map(\.writerIdentifier))
        #expect(event.outputs.map(\.writerVersion) == base.outputs.map(\.writerVersion))
        let unversioned = try SyncIdentifierFixture.changing(bytes, resourceType: "DocumentReference") { resource in
            resource["extension"] = (resource["extension"] as? [[String: Any]])?.filter {
                $0["url"] as? String != Canonicals.writerRecordVersion.value?.url.absoluteString
            }
        }
        let duplicated = try SyncIdentifierFixture.changing(bytes, resourceType: "DocumentReference") { resource in
            let identifiers = resource["identifier"] as? [[String: Any]] ?? []
            resource["identifier"] = identifiers + identifiers.filter(SyncIdentifierFixture.isSyncIdentifier)
        }
        for refused in [unversioned, duplicated] {
            #expect {
                try FHIRPointProjection.project(validatedBytes: refused, validatorIdentity: "test-only")
            } throws: { ($0 as? ServerError)?.status.code == 422 }
        }
    }

    @Test(arguments: [
        "duplicate", "second-coding", "type-text", "period", "path-segment", "bundle-identifier", "empty-bundle-identifier",
        "relative-scope", "other-scope", "missing-value", "writer-version", "writer-record", "without-native", "source-type",
        "native-typed-as-sync", "native-without-authority", "grove-identity-system", "device"
    ])
    func unsupportedSyncIdentifierShapesFailClosed(kind: String) throws {
        let golden = try SyncIdentifierFixture.bytes()
        let bytes: Data
        switch kind {
        case "duplicate", "writer-version", "writer-record", "without-native", "source-type", "native-typed-as-sync":
            bytes = try changingPrimary(golden, kind: kind)
        case "native-without-authority":
            // Grove refuses to disclose under a native system without an authority, so no sync identifier extends one.
            let text = String(decoding: golden, as: UTF8.self)
                .replacingOccurrences(of: SyncIdentifierFixture.nativeSystem, with: "urn:trove:test:native-healthkit-record")
            bytes = Data(text.utf8)
        case "grove-identity-system":
            // The writer-record identity numbered under the sync identifier's own system.
            let text = String(decoding: golden, as: UTF8.self).replacingOccurrences(
                of: "https://grovealliance.org/fhir/testing/identifiers/healthkit/writer-record/test/1", with: SyncIdentifierFixture.system
            )
            bytes = Data(text.utf8)
        case "device":
            let sync = try #require(try identifiers(golden).first(where: SyncIdentifierFixture.isSyncIdentifier))
            bytes = try SyncIdentifierFixture.changing(golden, resourceType: "Device") { resource in
                resource["identifier"] = (resource["identifier"] as? [[String: Any]] ?? []) + [sync]
            }
        default:
            bytes = try SyncIdentifierFixture.changingSyncIdentifier(golden) { change(&$0, kind: kind) }
        }
        #expect {
            try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-only")
        } throws: { ($0 as? ServerError)?.status.code == 422 }
    }

    private func changingPrimary(_ bytes: Data, kind: String) throws -> Data {
        try SyncIdentifierFixture.changing(bytes) { resource in
            var identifiers = try #require(resource["identifier"] as? [[String: Any]])
            var extensions = try #require(resource["extension"] as? [[String: Any]])
            switch kind {
            case "duplicate": identifiers += identifiers.filter(SyncIdentifierFixture.isSyncIdentifier)
            case "writer-version": extensions.removeAll { $0["url"] as? String == Canonicals.writerRecordVersion.value?.url.absoluteString }
            case "without-native": identifiers.removeAll { $0["type"] == nil }
            case "native-typed-as-sync":
                // Grove refuses to type the native UUID with the sync identifier's coding, which types that identifier alone.
                let sync = try #require(identifiers.first(where: SyncIdentifierFixture.isSyncIdentifier))
                let native = try #require(identifiers.firstIndex { $0["type"] == nil })
                identifiers[native]["type"] = sync["type"]
            case "source-type":
                extensions.removeAll { $0["url"] as? String == Canonicals.healthKitSourceTypeExtension.value?.url.absoluteString }
            default: identifiers.removeAll { ($0["system"] as? String)?.contains("/writer-record/") == true }
            }
            resource["identifier"] = identifiers
            resource["extension"] = extensions
        }
    }

    private func change(_ identifier: inout [String: Any], kind: String) {
        let scope = SyncIdentifierFixture.nativeSystem
        switch kind {
        case "second-coding":
            let codings = (identifier["type"] as? [String: Any])?["coding"] as? [Any] ?? []
            identifier["type"] = ["coding": codings + [["system": "https://example.org/identifier-type", "code": "other"]]]
        case "type-text": identifier["type"] = (identifier["type"] as? [String: Any] ?? [:]).merging(["text": "sync"]) { $1 }
        case "period": identifier["period"] = ["start": "2026-01-01"]
        case "path-segment": identifier["system"] = scope + "/sync-identifier/org.example.writer"
        case "bundle-identifier": identifier["system"] = scope + "/healthkit-sync-identifier/org_example"
        case "empty-bundle-identifier": identifier["system"] = scope + "/healthkit-sync-identifier/"
        case "relative-scope": identifier["system"] = "native-healthkit-record/healthkit-sync-identifier/org.example.writer"
        case "other-scope": identifier["system"] = "https://example.org/other-store/healthkit-sync-identifier/org.example.writer"
        default: identifier["value"] = nil
        }
    }

    @Test
    func retractionNeverCarriesASyncIdentifier() throws {
        let active = try Data(contentsOf: NativeIdentifierFixture.healthKitURL())
        let deleted = try RetractionEventFixture.bytes(activeBytes: active, retractionSystem: IdentifierSystem("urn:trove:test:record-retraction"))
        _ = try FHIRPointProjection.project(validatedBytes: deleted, validatorIdentity: "test-only")
        let sync = try #require(try identifiers(SyncIdentifierFixture.bytes()).first(where: SyncIdentifierFixture.isSyncIdentifier))
        let bytes = try SyncIdentifierFixture.changing(deleted, resourceType: "Device") { resource in
            resource["identifier"] = (resource["identifier"] as? [[String: Any]] ?? []) + [sync]
        }
        #expect {
            try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-only")
        } throws: { ($0 as? ServerError)?.status.code == 422 }
    }

    private func identifiers(_ bytes: Data) throws -> [[String: Any]] {
        let document = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let entries = try #require(document["entry"] as? [[String: Any]])
        let resources = entries.compactMap { $0["resource"] as? [String: Any] }
        let observation = try #require(resources.first { $0["resourceType"] as? String == "Observation" })
        return try #require(observation["identifier"] as? [[String: Any]])
    }
}
