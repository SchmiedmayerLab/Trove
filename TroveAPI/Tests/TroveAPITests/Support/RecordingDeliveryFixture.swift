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
import Testing
import TroveAPIClient


enum RecordingDeliveryFixture {
    static let start = Date(timeIntervalSince1970: 1_787_005_800)
    static let end = start.addingTimeInterval(1)

    static func make() throws -> (EventDeliveryJournal.Payload, Components.Schemas.RecordingTransferDeclaration) {
        let record = try RecordFixture.make(
            sourceID: DeliveryFixture.sourceID, registrationID: DeliveryFixture.epoch, seed: "recording-transfer", fixture: "record-workout-route"
        )
        var object = try #require(JSONSerialization.jsonObject(with: record.json) as? [String: Any])
        var entries = try #require(object["entry"] as? [[String: Any]])
        let index = try #require(entries.firstIndex { ($0["resource"] as? [String: Any])?["resourceType"] as? String == "DocumentReference" })
        var document = try #require(entries[index]["resource"] as? [String: Any])
        var content = try #require(document["content"] as? [[String: Any]])
        var attachment = try #require(content[0]["attachment"] as? [String: Any])
        let encoded = try #require(attachment.removeValue(forKey: "data") as? String)
        let bytes = try #require(Data(base64Encoded: encoded))
        attachment["url"] = "recordings/route.csv"
        content[0]["attachment"] = attachment
        document["content"] = content
        let dates = TroveDateTranscoder()
        document["context"] = ["period": ["start": try dates.encode(start), "end": try dates.encode(end)]]
        entries[index]["resource"] = document
        object["entry"] = entries
        let external = try ExchangeRecord(validating: JSONSerialization.data(withJSONObject: object))
        let output = try #require(external.outputFullURLs.first)
        let sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let declaration = Components.Schemas.RecordingTransferDeclaration(
            attachmentPath: "recordings/route.csv",
            outputFullUrl: output,
            profile: try #require(Profile.healthkitRecordingDocument.value?.url.absoluteString),
            format: RegisteredRecordingFormat.locationTrackSamples.rawValue,
            effectiveAt: start,
            effectiveEnd: end,
            content: .init(
                encoding: .identity,
                storedByteCount: Int64(bytes.count),
                storedSHA256: sha256,
                sourceByteCount: Int64(bytes.count),
                sourceSHA256: sha256
            ),
            targets: [.init(consentId: DeliveryFixture.consentID.uuidString.lowercased(), outputFullUrls: [output])]
        )
        let payload = EventDeliveryJournal.Payload(
            bytes: external.json,
            targets: [.init(consentID: DeliveryFixture.consentID, outputFullURLs: [output])],
            recordings: [.init(relativePath: declaration.attachmentPath, byteCount: bytes.count) { try $0(bytes) }]
        )
        return (payload, declaration)
    }

    static func registration(_ transfer: DeliveryRecordingTransfer) -> Components.Schemas.RecordingTransferRegistration {
        .init(
            sourceId: transfer.sourceID.uuidString.lowercased(),
            transferId: transfer.transferID.uuidString.lowercased(),
            declarationSHA256: transfer.commitment.sha256,
            storedByteCount: transfer.commitment.declaration.content.storedByteCount,
            storedSHA256: transfer.commitment.declaration.content.storedSHA256
        )
    }

    static func receipt(_ transfer: DeliveryRecordingTransfer) -> Components.Schemas.RecordingTransferReceipt {
        .init(
            sourceId: transfer.sourceID.uuidString.lowercased(),
            transferId: transfer.transferID.uuidString.lowercased(),
            artifactId: UUID().uuidString.lowercased(),
            declarationSHA256: transfer.commitment.sha256,
            storedByteCount: transfer.commitment.declaration.content.storedByteCount,
            storedSHA256: transfer.commitment.declaration.content.storedSHA256,
            verifiedAt: start,
            expiresAt: start.addingTimeInterval(3600)
        )
    }
}
