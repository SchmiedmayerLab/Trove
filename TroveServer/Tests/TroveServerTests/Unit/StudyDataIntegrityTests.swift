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


struct StudyDataIntegrityTests {
    @Test
    func retainedBytesRequireMatchingIntegrityAndAnAdmittedProjection() throws {
        let event = try StudyProjectionFixture.event()
        let digest = SHA256.hash(data: event.rawBytes).map { String(format: "%02x", $0) }.joined()
        let retained = try StudyDataExportStore.validateRetainedRecord(bytes: event.rawBytes, digest: digest, validator: "test-only")
        #expect(retained.rawBytes == event.rawBytes)
        let invalid = Data("synthetic invalid retained content".utf8)
        let invalidDigest = SHA256.hash(data: invalid).map { String(format: "%02x", $0) }.joined()
        for (bytes, sha, validator) in [
            (event.rawBytes + Data([32]), digest, "test-only"), (event.rawBytes, "mismatched", "test-only"),
            (event.rawBytes, digest, ""), (invalid, invalidDigest, "test-only"), (Data(), digest, "test-only"),
            (Data(repeating: 32, count: FHIRValidationClient.maximumBytes + 1), digest, "test-only")
        ] {
            #expect { try StudyDataExportStore.validateRetainedRecord(bytes: bytes, digest: sha, validator: validator) } throws: {
                let error = $0 as? ServerError
                return error?.status.code == 500 && error?.detail.contains("synthetic") == false
            }
        }
    }
}
