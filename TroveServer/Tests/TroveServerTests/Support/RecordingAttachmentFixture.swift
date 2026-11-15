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
import Testing
import TroveAPIClient
import TroveAPITypes
@testable import TroveServer


/// Synthetic record identities with real CSV, compression and attachment commitments; full IG validation is a separate lane.
struct RecordingAttachmentFixture: Sendable {
    let record: Data
    let stored: Data
    var declaration: Components.Schemas.RecordingTransferDeclaration

    static func make(source: SourceBinding, consentID: UUID, compressed: Bool) throws -> Self {
        let original = try LocalPointEventFixture.bytes(source: source, fixtureURL: FHIRRecordingProjectionTests.fixtureURL())
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var entries = try #require(object["entry"] as? [[String: Any]])
        let index = try #require(entries.firstIndex { ($0["resource"] as? [String: Any])?["resourceType"] as? String == "DocumentReference" })
        let fullURL = try #require(entries[index]["fullUrl"] as? String)
        var document = try #require(entries[index]["resource"] as? [String: Any])
        var contents = try #require(document["content"] as? [[String: Any]])
        var attachment = try #require(contents[0]["attachment"] as? [String: Any])
        let encoded = try #require(attachment.removeValue(forKey: "data") as? String)
        let prior = try #require(Data(base64Encoded: encoded))
        let dates = TroveDateTranscoder()
        let date = try dates.decode(dates.encode(Date()))
        let bytes = try Self.retimedCSV(prior, at: date)
        let path = "recordings/route.csv", stored = try compressed ? compress(bytes) : bytes
        attachment["url"] = path
        attachment["size"] = bytes.count
        attachment["hash"] = Data(Insecure.SHA1.hash(data: bytes)).base64EncodedString()
        contents[0]["attachment"] = attachment
        document["content"] = contents
        entries[index]["resource"] = document
        object["entry"] = entries
        return try .init(
            record: ExchangeRecord(validating: JSONSerialization.data(withJSONObject: object)).json,
            stored: stored,
            declaration: .init(
                attachmentPath: path,
                outputFullUrl: fullURL,
                profile: FHIRRecordingProjection.profile,
                format: FHIRRecordingProjection.routeFormat,
                effectiveAt: date,
                effectiveEnd: date,
                content: .init(
                    encoding: compressed ? .zstd : .identity,
                    storedByteCount: Int64(stored.count),
                    storedSHA256: ArtifactStore.digest(stored),
                    sourceByteCount: Int64(bytes.count),
                    sourceSHA256: ArtifactStore.digest(bytes)
                ),
                targets: [.init(consentId: consentID.uuidString, outputFullUrls: [fullURL])]
            )
        )
    }

    static func retimedCSV(_ prior: Data, at date: Date) throws -> Data {
        let reader = try RecordingCSVReader(prior, format: .locationTrackSamples)
        var writer = try RecordingCSVWriter(format: .locationTrackSamples)
        for row in reader.rows {
            try writer.append(reader.columns.enumerated().map { index, column in
                column == "timestamp" ? .timestamp(date) : .text(row.fields[index])
            })
        }
        return writer.data()
    }

    static func compress(_ bytes: Data) throws -> Data {
        var compressor = try Zstd.StreamCompressor(sourceByteCount: Int64(bytes.count), maximumOutputByteCount: Int64(bytes.count + 1024))
        var result = Data()
        try compressor.write(bytes) { result.append($0) }
        try compressor.finish { result.append($0) }
        return result
    }

    func submission(sourceID: UUID, receipt: Components.Schemas.RecordingTransferReceipt) throws -> Components.Schemas.RecordBundleSubmission {
        let event = Components.Schemas.EventSubmission(eventBase64: record.base64EncodedString(), targets: declaration.targets)
        var request = try ClinicalRecordBundleTests.bundle([event], sourceID: sourceID)
        request.records[0].recordings = [
            .init(attachmentPath: declaration.attachmentPath, transferId: receipt.transferId, artifactId: receipt.artifactId)
        ]
        return request
    }
}
