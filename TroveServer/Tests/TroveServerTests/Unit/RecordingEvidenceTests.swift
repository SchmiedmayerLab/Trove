//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import TroveServer


struct RecordingEvidenceTests {
    @Test(arguments: [false, true])
    func custodyEvidencePreservesEmptyAndSubsecondBounds(empty: Bool) throws {
        let first = empty ? nil : Date(timeIntervalSince1970: 1_787_005_800.123456)
        let last = empty ? nil : Date(timeIntervalSince1970: 1_787_005_800.987654)
        let original = RecordingContentVerification(
            bounds: try .init(first: first, last: last), attachmentSHA1: Data(repeating: 7, count: 20)
        )
        let retained = try RecordingContentVerification(restoring: original.serialized)
        #expect(retained.bounds.first == first && retained.bounds.last == last)
        #expect(retained.attachmentSHA1 == original.attachmentSHA1)
    }

    @Test(arguments: ["missing-last", "missing-first", "reversed", "hash", "malformed", "oversized"])
    func corruptEvidenceCannotBeUsedForProjection(reason: String) throws {
        var evidence: [String: Any] = ["first": 1.0, "last": 2.0, "attachmentSHA1": Data(repeating: 7, count: 20).base64EncodedString()]
        switch reason {
        case "missing-last": evidence["last"] = nil
        case "missing-first": evidence["first"] = nil
        case "reversed": evidence["first"] = 3.0
        case "hash": evidence["attachmentSHA1"] = Data(repeating: 7, count: 19).base64EncodedString()
        default: break
        }
        var serialized = String(decoding: try JSONSerialization.data(withJSONObject: evidence), as: UTF8.self)
        if reason == "malformed" { serialized = "synthetic malformed content" }
        if reason == "oversized" { serialized = String(repeating: "x", count: 1025) }
        #expect { try RecordingContentVerification(restoring: serialized) } throws: {
            ($0 as? ServerError)?.detail == "Retained recording evidence is unavailable"
        }
    }
}
