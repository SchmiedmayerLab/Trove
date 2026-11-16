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
import GroveSensorKitFHIR
import OpenAPIRuntime
import Testing
import TroveAPITypes
@testable import TroveServer


struct NativeRecordingVerificationTests {
    @Test("Original JSON recordings verify through the shared grammar and both transport encodings", arguments: [false, true])
    func verifiesOriginalBytes(compressed: Bool) async throws {
        let source = Data("{\"integer\":123456789012345678901234567890,\"nested\":[true,null,\"synthetic\"]}".utf8)
        let stored = try compressed ? Self.compress(source) : source
        let declaration = try Self.declaration(source: source, stored: stored, compressed: compressed)
        let result = try await RecordingContentVerification.verify(
            HTTPBody(stored), declaration: declaration, maximumWindowByteCount: 8 * 1024 * 1024
        )
        #expect(result.attachmentSHA1 == Data(Insecure.SHA1.hash(data: source)))
        #expect(result.bounds.first == nil && result.bounds.last == nil)
        let retained = try RecordingContentVerification(restoring: result.serialized)
        #expect(retained.attachmentSHA1 == result.attachmentSHA1)
    }

    @Test("Matching byte commitments do not admit a duplicate-member JSON object", arguments: [false, true])
    func rejectsInvalidGrammar(compressed: Bool) async throws {
        let source = Data("{\"duplicate\":1,\"duplicate\":2}".utf8)
        let stored = try compressed ? Self.compress(source) : source
        let declaration = try Self.declaration(source: source, stored: stored, compressed: compressed)
        await #expect(throws: (any Error).self) {
            try await RecordingContentVerification.verify(
                HTTPBody(stored), declaration: declaration, maximumWindowByteCount: 8 * 1024 * 1024
            )
        }
    }

    @Test("The exact source representation is independently bound inside a valid compressed stream")
    func refusesSourceDigestMismatch() async throws {
        let source = Data("{\"synthetic\":1}".utf8), other = Data("{\"synthetic\":2}".utf8)
        let stored = try Self.compress(source)
        let declaration = try Self.declaration(source: other, stored: stored, compressed: true)
        await #expect(throws: (any Error).self) {
            try await RecordingContentVerification.verify(
                HTTPBody(stored), declaration: declaration, maximumWindowByteCount: 8 * 1024 * 1024
            )
        }
    }
}


extension NativeRecordingVerificationTests {
    private static func declaration(source: Data, stored: Data, compressed: Bool) throws -> RecordingTransferDeclaration {
        let sourceToken = try #require(SensorKitCatalog.current.entries.first {
            $0.rawFormats.contains(.nativeRecording) && $0.implementedOutput != nil
        }).sourceToken
        let fullURL = "urn:uuid:73f859eb-b777-4ff7-9dc4-8ef872a5f354"
        return try .init(
            attachmentPath: "recordings/native.json",
            outputFullURL: fullURL,
            profile: SensorKitContract.recordingDocumentProfile,
            format: .nativeRecording,
            effectiveAt: FHIRSensorKitFixture.start,
            effectiveEnd: FHIRSensorKitFixture.end,
            content: .init(
                storedByteCount: stored.count,
                storedSHA256: ArtifactStore.digest(stored),
                sourceByteCount: source.count,
                sourceSHA256: ArtifactStore.digest(source),
                encoding: compressed ? .zstd : .identity
            ),
            targets: [.init(consentID: UUID(), outputFullURLs: [fullURL])],
            sourceTypeIdentifier: sourceToken
        )
    }

    private static func compress(_ bytes: Data) throws -> Data {
        var compressor = try Zstd.StreamCompressor(sourceByteCount: Int64(bytes.count), maximumOutputByteCount: Int64(bytes.count + 1024))
        var output = Data()
        try compressor.write(bytes) { output.append($0) }
        try compressor.finish { output.append($0) }
        return output
    }
}
