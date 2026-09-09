//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import Testing
@testable import TroveServer


struct FHIRValidationClientTests {
    private static let identity = "sha256:" + String(repeating: "a", count: 64)
    private static let bytes = Data("exact original bytes".utf8)

    @Test
    func onlyExactPinnedSuccessAdmitsTheOriginalBytes() async throws {
        let validator = FHIRValidationClient(expectedIdentity: Self.identity) { input in
            #expect(input == Self.bytes)
            return (200, try Self.reply())
        }
        #expect(try await validator.validate(Self.bytes) == Self.identity)
    }

    @Test(arguments: ["digest", "revision", "identity", "false", "code", "oversized", "malformed", "redirect", "unavailable"])
    func untrustedOrIncompleteResultFailsClosed(change: String) async throws {
        let validator = FHIRValidationClient(expectedIdentity: Self.identity) { _ in
            switch change {
            case "oversized": return (200, Data(repeating: 32, count: 2049))
            case "malformed": return (200, Data("{}".utf8))
            case "redirect": return (302, try Self.reply())
            case "unavailable": return (503, try Self.reply())
            default: return (200, try Self.reply(change: change))
            }
        }
        await #expect {
            try await validator.validate(Self.bytes)
        } throws: { ($0 as? ServerError)?.status.code == 503 }
    }

    @Test
    func pinnedInvalidResultIsAValidationRefusal() async throws {
        let validator = FHIRValidationClient(expectedIdentity: Self.identity) { _ in
            (422, try Self.reply(change: "invalid"))
        }
        await #expect {
            try await validator.validate(Self.bytes)
        } throws: { ($0 as? ServerError)?.status.code == 422 }
    }

    @Test(arguments: [nil, "", "sha256:missing", "sha256:" + String(repeating: "A", count: 64)])
    func missingOrMalformedPinNeverContactsWorker(identity: String?) async throws {
        let validator = FHIRValidationClient(expectedIdentity: identity) { _ in
            Issue.record("Unpinned worker must never receive clinical bytes")
            return (200, Data())
        }
        await #expect {
            try await validator.validate(Self.bytes)
        } throws: { ($0 as? ServerError)?.status.code == 503 }
    }

    @Test(arguments: [0, 4 * 1024 * 1024 + 1])
    func inputBoundsAreCheckedBeforeWorker(size: Int) async throws {
        let validator = FHIRValidationClient(expectedIdentity: Self.identity) { _ in
            Issue.record("Invalid input length must not reach worker")
            return (200, Data())
        }
        await #expect {
            try await validator.validate(Data(repeating: 32, count: size))
        } throws: { ($0 as? ServerError)?.status.code == (size == 0 ? 422 : 413) }
    }

    @Test
    func cancellationIsNotReportedAsInvalidFHIR() async throws {
        let validator = FHIRValidationClient(expectedIdentity: Self.identity) { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) { try await validator.validate(Self.bytes) }
    }
}


extension FHIRValidationClientTests {
    private static func reply(change: String = "") throws -> Data {
        var payload: [String: Any] = [
            "valid": change != "false" && change != "invalid",
            "sha256": change == "digest" ? "wrong" : SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "contractRevision": change == "revision" ? "wrong" : FHIRValidationClient.contractRevision,
            "validatorIdentity": change == "identity" ? "wrong" : identity
        ]
        if change == "code" || change == "invalid" { payload["code"] = "invalid_fhir" }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}
