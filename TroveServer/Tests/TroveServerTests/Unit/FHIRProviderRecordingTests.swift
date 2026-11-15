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
import ModelsR4
import OpenAPIRuntime
import Testing
@testable import TroveServer


struct FHIRProviderRecordingTests {
    @Test(arguments: ProviderNativeRecording.Source.allCases)
    func exactExternalRecordingRetainsProviderScope(source: ProviderNativeRecording.Source) async throws {
        let bytes = Data(" {\"samples\":[{\"value\":71.00,\"integer\":12345678901234567890}]}\n".utf8)
        let input = try await recording(source: source, bytes: bytes)
        let result = try ProviderRecordingFHIR.convert(input, context: context(source))
        let record = try #require(result.record)
        let graph = try ExchangeGraph(validating: record.json, kind: .active)
        let documentEntry = try #require(graph.bundle.entry?.first { $0.resource?.resourceType == "DocumentReference" })
        let fullURL = try #require(documentEntry.fullUrl?.value?.url.absoluteString)
        let attachment = try await attachment(input, bytes: bytes, fullURL: fullURL)
        let event = try FHIRPointProjection.project(validatedBytes: record.json, validatorIdentity: "synthetic-receiver", recordings: [attachment])
        let output = try #require(event.outputs.first)
        #expect(event.outputs.count == 1 && output.value == .recording)
        #expect(output.sourceTypeIdentifier == input.source.rawValue.split(separator: "/", maxSplits: 1).last.map(String.init))
        #expect(output.sourceRepositoryKind?.rawValue == input.source.rawValue.split(separator: "/", maxSplits: 1).first.map(String.init))
        #expect(output.profile == Profile.groveSensorRecordingDocument.value?.url.absoluteString)
        #expect(output.measurementBounds == (try .init(start: #require(input.interval).start, end: #require(input.interval).end)))
        var document = try #require(documentEntry.resource?.get() as? DocumentReference)
        document.context = nil
        #expect(throws: (any Error).self) { try FHIRRecordingProjection.project(document, external: attachment) }
    }

    private func recording(source: ProviderNativeRecording.Source, bytes: Data) async throws -> ProviderNativeRecording {
        let chunks = AsyncStream<Data> { continuation in
            continuation.yield(bytes.prefix(3))
            continuation.yield(bytes.dropFirst(3))
            continuation.finish()
        }
        let file = try await RecordingFile.stage(chunks: chunks, maximumByteCount: Int64(bytes.count))
        return try .init(
            id: "synthetic-source-record",
            source: source,
            title: "Synthetic recording",
            file: file,
            attachmentPath: "recordings/provider.json",
            interval: DateInterval(start: FHIRSensorKitFixture.start, end: FHIRSensorKitFixture.end),
            admission: .verifiedSanitizedInput
        )
    }

    private func attachment(_ input: ProviderNativeRecording, bytes: Data, fullURL: String) async throws -> ClinicalRecordingAttachment {
        let interval = try #require(input.interval), digest = ArtifactStore.digest(bytes)
        let declaration = try RecordingTransferDeclaration(
            attachmentPath: input.attachmentPath,
            outputFullURL: fullURL,
            profile: #require(Profile.groveSensorRecordingDocument.value?.url.absoluteString),
            format: .providerRecording,
            effectiveAt: interval.start,
            effectiveEnd: interval.end,
            content: .init(
                storedByteCount: bytes.count, storedSHA256: digest, sourceByteCount: bytes.count, sourceSHA256: digest, encoding: .identity
            ),
            targets: [.init(consentID: UUID(), outputFullURLs: [fullURL])],
            sourceTypeIdentifier: #require(input.source.rawValue.split(separator: "/", maxSplits: 1).last.map(String.init))
        )
        let content = try await RecordingContentVerification.verify(
            HTTPBody(bytes), declaration: declaration, maximumWindowByteCount: 8 * 1024 * 1024
        )
        let owner = UUID()
        return try .init(
            reference: .init(
                id: UUID(),
                ownerID: owner,
                purpose: .recording,
                digest: digest,
                byteCount: bytes.count,
                scope: .participantSource(.init(participantID: owner, sourceBindingID: UUID()))
            ),
            declaration: declaration,
            content: content
        )
    }

    private func context(_ source: ProviderNativeRecording.Source) throws -> ProviderConversionContext {
        let producer = try ExchangeProducer(
            identityScope: .init(
                root: IdentifierSystem("https://example.test/provider-source"),
                keyID: "synthetic",
                epoch: KeyEpoch(1),
                key: SymmetricKey(data: Data(repeating: 0x35, count: 32))
            ),
            subject: .logical(.init(system: IdentifierSystem("https://example.test/participants"), value: "synthetic-participant")),
            application: .init(name: "Trove", bundleIdentifier: "org.example.Trove", version: "1"),
            host: .init(operatingSystemName: "Linux", operatingSystemVersion: "6")
        )
        let scope = try BusinessIdentifier(system: IdentifierSystem("https://example.test/provider-scope"), value: "synthetic")
        return try .init(
            producer: producer,
            scope: source == .ouraHeartRate ? .global(scope) : .account(scope),
            instant: FHIRSensorKitFixture.end.addingTimeInterval(60),
            sourceTimeZone: #require(TimeZone(secondsFromGMT: 0))
        )
    }
}
