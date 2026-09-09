//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPITypes


struct EventReceiptTests {
    private var receipt: Components.Schemas.EventReceipt {
        .init(
            eventId: "fd9f41b3-0e17-4362-9f10-a734ca10b58a",
            sourceId: "30508c4b-fc32-4f76-8028-c09b27a2cb11",
            producerEventIdentifier: .init(
                system: "https://example.org/events",
                value: "e0:30508c4b-fc32-4f76-8028-c09b27a2cb11:9007199254740993"
            ),
            payloadSHA256: String(repeating: "a", count: 64),
            targetIntentSHA256: String(repeating: "b", count: 64),
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            nodeCount: 8
        )
    }

    @Test
    func custodyIdentitySurvivesWireRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bytes = try encoder.encode(receipt)
        let decoded = try decoder.decode(Components.Schemas.EventReceipt.self, from: bytes)
        #expect(decoded == receipt)
        #expect(decoded.eventId != decoded.producerEventIdentifier.value)
    }

    @Test(arguments: ["sourceId", "producerEventIdentifier", "payloadSHA256", "targetIntentSHA256"])
    func incompleteAcknowledgementCannotDecode(missingField: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bytes = try encoder.encode(receipt)
        var object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object.removeValue(forKey: missingField)
        let incomplete = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try decoder.decode(Components.Schemas.EventReceipt.self, from: incomplete)
        }
    }
}
