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
import GroveFoundation
import struct ModelsR4.DocumentReference
import OpenAPIRuntime
import Testing
import TroveAPITypes
@testable import TroveServer


struct RecordingContentVerificationTests {
    @Test(arguments: [false, true], [1, 7, 64 * 1024])
    func completeRepresentationsHaveIdenticalSourceEvidence(compressed: Bool, chunkSize: Int) async throws {
        let source = try Self.source()
        let stored = try compressed ? Self.compressed(source) : source
        let declaration = try Self.declaration(source: source, stored: stored, compressed: compressed)
        let input = Input(bytes: stored, chunkSize: chunkSize)
        let result = try await RecordingContentVerification.verify(input.body, declaration: declaration, maximumWindowByteCount: 8 * 1024 * 1024)
        #expect(result.bounds.first == Date(timeIntervalSince1970: 1_787_005_800))
        #expect(result.bounds.last == Date(timeIntervalSince1970: 1_787_005_801))
        #expect(result.attachmentSHA1 == Data(Insecure.SHA1.hash(data: source)))
        #expect(await input.offset == stored.count)
    }

    @Test(arguments: ["stored-digest", "source-digest", "stored-short", "stored-long", "source-short", "source-long"])
    func exactCountsAndDigestsAreRequired(corruption: String) async throws {
        let source = try Self.source(), stored = try Self.compressed(source)
        var declaration = try Self.apiDeclaration(source: source, stored: stored, compressed: true)
        switch corruption {
        case "stored-digest": declaration.content.storedSHA256 = String(repeating: "0", count: 64)
        case "source-digest": declaration.content.sourceSHA256 = String(repeating: "0", count: 64)
        case "stored-short": declaration.content.storedByteCount -= 1
        case "stored-long": declaration.content.storedByteCount += 1
        case "source-short": declaration.content.sourceByteCount -= 1
        default: declaration.content.sourceByteCount += 1
        }
        let retained = try RecordingTransferDeclaration(declaration)
        await #expect {
            try await RecordingContentVerification.verify(
                Input(bytes: stored, chunkSize: 7).body, declaration: retained, maximumWindowByteCount: 8 * 1024 * 1024
            )
        } throws: { ($0 as? TroveServer.ServerError)?.status.code == 422 }
    }

    @Test(arguments: ["header", "timestamp", "unfinished-row", "truncated-frame", "trailing-data", "second-frame"])
    func matchingDigestsCannotAdmitInvalidCSVOrCompressedFrames(corruption: String) async throws {
        var source = try Self.source()
        if corruption == "header" {
            source = Data(String(decoding: source, as: UTF8.self).replacingOccurrences(of: "timestamp,", with: "unknown,").utf8)
        }
        if corruption == "timestamp" {
            source = Data(String(decoding: source, as: UTF8.self).replacingOccurrences(of: "1787005800,", with: "NaN,").utf8)
        }
        if corruption == "unfinished-row" { source.removeLast() }
        var stored = try Self.compressed(source)
        if corruption == "truncated-frame" { stored.removeLast() }
        if corruption == "trailing-data" { stored.append(0) }
        if corruption == "second-frame" { stored.append(try Self.compressed(source)) }
        let declaration = try Self.declaration(source: source, stored: stored, compressed: true)
        let input = Input(bytes: stored, chunkSize: 7)
        await #expect {
            try await RecordingContentVerification.verify(input.body, declaration: declaration, maximumWindowByteCount: 8 * 1024 * 1024)
        } throws: { ($0 as? TroveServer.ServerError)?.status.code == 422 }
    }

    @Test
    func interruptedStorageReadsRemainRetryableAndCancellationPropagates() async throws {
        let source = try Self.source()
        let declaration = try Self.declaration(source: source, stored: source, compressed: false)
        let chunks = [String(decoding: source.prefix(30), as: UTF8.self), String(decoding: source.dropFirst(30), as: UTF8.self)]
        let interrupted = ObjectStorageStreamSource(chunks, failureAt: 1)
        await #expect {
            try await RecordingContentVerification.verify(interrupted.body(), declaration: declaration, maximumWindowByteCount: 8 * 1024 * 1024)
        } throws: { ($0 as? TroveServer.ServerError)?.status.code == 503 }
        let cancelled = ObjectStorageStreamSource(chunks, cancellationAt: 1)
        let task = Task {
            try await RecordingContentVerification.verify(cancelled.body(), declaration: declaration, maximumWindowByteCount: 8 * 1024 * 1024)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}


extension RecordingContentVerificationTests {
    private actor Input {
        let bytes: Data
        let chunkSize: Int
        private(set) var offset = 0

        nonisolated var body: HTTPBody {
            HTTPBody(AsyncThrowingStream(unfolding: { await self.next() }), length: .unknown)
        }

        init(bytes: Data, chunkSize: Int) { self.bytes = bytes; self.chunkSize = chunkSize }

        private func next() -> HTTPBody.ByteChunk? {
            guard offset < bytes.count else {
                return nil
            }
            let count = min(chunkSize, bytes.count - offset)
            defer { offset += count }
            return ArraySlice(bytes[offset..<(offset + count)])
        }
    }

    private static func source() throws -> Data {
        let graph = try ExchangeGraph(validating: Data(contentsOf: FHIRRecordingProjectionTests.fixtureURL()), kind: .active)
        let document = try #require(graph.bundle.entry?.compactMap { $0.resource?.get(if: DocumentReference.self) }.first)
        return try #require(document.content.first?.attachment.data?.value?.data())
    }

    private static func compressed(_ bytes: Data) throws -> Data {
        var compressor = try Zstd.StreamCompressor(sourceByteCount: Int64(bytes.count), maximumOutputByteCount: Int64(bytes.count + 1024))
        var output = Data()
        try compressor.write(bytes) { output.append($0) }
        try compressor.finish { output.append($0) }
        return output
    }

    private static func declaration(source: Data, stored: Data, compressed: Bool) throws -> RecordingTransferDeclaration {
        try .init(apiDeclaration(source: source, stored: stored, compressed: compressed))
    }

    private static func apiDeclaration(
        source: Data, stored: Data, compressed: Bool
    ) throws -> Components.Schemas.RecordingTransferDeclaration {
        let output = "urn:uuid:fe604690-0681-4bb2-ad3c-d5b28c013143"
        return .init(
            attachmentPath: "recordings/route.csv",
            outputFullUrl: output,
            profile: FHIRRecordingProjection.profile,
            format: RegisteredRecordingFormat.locationTrackSamples.rawValue,
            effectiveAt: Date(timeIntervalSince1970: 1_787_005_800),
            effectiveEnd: Date(timeIntervalSince1970: 1_787_005_801),
            content: .init(
                encoding: compressed ? .zstd : .identity,
                storedByteCount: Int64(stored.count),
                storedSHA256: ArtifactStore.digest(stored),
                sourceByteCount: Int64(source.count),
                sourceSHA256: ArtifactStore.digest(source)
            ),
            targets: [.init(consentId: UUID().uuidString, outputFullUrls: [output])]
        )
    }
}
