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
@testable import TroveServer


struct CollectionCapacityConfigurationTests {
    @Test
    func admissionAndExportBudgetsAreIndependent() throws {
        let configured = try CollectionCapacityConfiguration(environment: [
            "COLLECTION_MAX_RECORD_BYTES": "6291456", "COLLECTION_MAX_BUNDLE_BYTES": "6292480",
            "COLLECTION_MAX_ENVELOPE_BYTES": "9437184", "STUDY_EXPORT_MAX_BUNDLE_BYTES": "33554432",
            "STUDY_EXPORT_MAX_PAGE_BYTES": "50331648"
        ])
        #expect(configured.admission.recordBytes == 6 * 1024 * 1024)
        #expect(configured.export.bundleBytes == 32 * 1024 * 1024)
        #expect(configured.export.pageBytes == 48 * 1024 * 1024)
        #expect(throws: (any Error).self) {
            try CollectionCapacityConfiguration(environment: ["STUDY_EXPORT_MAX_BUNDLE_BYTES": "33554432"])
        }
        #expect(throws: (any Error).self) {
            try CollectionCapacityConfiguration(environment: ["STUDY_EXPORT_MAX_PAGE_BYTES": "0"])
        }
    }

    @Test
    func projectionUsesConfiguredLimitIncludingContainerPunctuation() throws {
        let value = try StudyProjectionJSON.object(["number": .scalar(Data("1.234567890123456789".utf8)), "text": .string("value")])
        let bytes = try value.encoded()
        #expect(try value.encoded(maximumBytes: bytes.count) == bytes)
        #expect(throws: StudyProjectionJSON.Failure.outputTooLarge) { try value.encoded(maximumBytes: bytes.count - 1) }
        #expect(throws: StudyProjectionJSON.Failure.outputTooLarge) { try value.encoded(maximumBytes: 0) }
    }

    @Test
    func retainedRecordLexemesSupportLargerHardCeilingWithoutLowerAdmissionPolicy() throws {
        let prefix = Data((#"{"entry":[{"resource":{"resourceType":"Observation","valueQuantity":{"value":1.234567890123456789},"#
            + #""note":[{"text":""#).utf8)
        let suffix = Data(#""}]}}]}"#.utf8)
        let bytes = prefix + Data(repeating: 120, count: 5 * 1024 * 1024) + suffix
        #expect(try ValidatedQuantityLexemes.extract(from: bytes)[0] == "1.234567890123456789")
        #expect(bytes.count > EventSubmissionLimits.Configuration.standard.recordBytes)
        #expect(bytes.count < FHIRValidationClient.maximumBytes)
    }
}
