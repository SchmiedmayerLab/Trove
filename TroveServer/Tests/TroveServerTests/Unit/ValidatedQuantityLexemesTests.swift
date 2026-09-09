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


struct ValidatedQuantityLexemesTests {
    @Test(arguments: [
        "123456789012345678901234567890123456789012345678901234567890.123456789012345678900",
        "-0.00000000000000000000000000000000000000000000000000000000000000000",
        "123.450000", "1e99999", "9.900E-002", "-2.7000e+0004", "0", "-0"
    ])
    func preservesOriginalNumberTokenWithoutDecimalConversion(token: String) throws {
        #expect(try ValidatedQuantityLexemes.extract(from: Self.event(token)) == [0: token])
    }

    @Test
    func matchesEscapedKeysAndResourceTypeInEitherMemberOrder() throws {
        let json = #"""
            {"\u0065ntry":[
              {"resource":{"valueQuantity":{"value":12.3400},"resourceType":"Observation"}},
              {"resource":{"resourceType":"Patient"}},
              {"res\u006furce":{"resourceType":"Observati\u006fn","value\u0051uantity":{"va\u006cue":9.900E-02}}}
            ]}
            """#
        #expect(try ValidatedQuantityLexemes.extract(from: Data(json.utf8)) == [0: "12.3400", 2: "9.900E-02"])
    }

    @Test
    func ignoresNestedAndUnrelatedQuantitiesAndStringDecoys() throws {
        let json = #"""
            {"entry":[
              {"resource":{"resourceType":"Observation","component":[{"valueQuantity":{"value":999}}],
                "extension":[{"valueQuantity":{"value":888}}],"valueQuantity":{"value":7.000},
                "text":"escaped quote: \"; slash: \\; fake valueQuantity.value: 777"}},
              {"valueQuantity":{"value":666},"resource":{"resourceType":"Observation","component":[{"valueQuantity":{"value":555}}]}},
              {"resource":{"resourceType":"Device","valueQuantity":{"value":444}}}
            ],"other":{"entry":[{"resource":{"resourceType":"Observation","valueQuantity":{"value":333}}}]}}
            """#
        #expect(try ValidatedQuantityLexemes.extract(from: Data(json.utf8)) == [0: "7.000"])
    }

    @Test(arguments: ["01", "-", "1.", "+1", "NaN", "Infinity", "1e", "1e+", "1e-", "--1", "0x1", "1 2", "\"1.00\"", "null"])
    func malformedQuantityTokensAreRejected(token: String) {
        #expect(throws: ValidatedQuantityLexemes.Failure.invalidJSON) {
            try ValidatedQuantityLexemes.extract(from: Self.event(token))
        }
    }

    @Test(arguments: [
        #"{"entry":[],"entry":[]}"#,
        #"{"entry":[{"resource":{"resourceType":"Observation","valueQuantity":{"value":1,"\u0076alue":2}}}]}"#,
        #"{"entry":[],}"#,
        #"{"entry":[,]}"#,
        #"{"entry":[]} trailing"#,
        #"{"text":"\uD800","entry":[]}"#,
        #"{"text":"\q","entry":[]}"#,
        "[]", "true", ""
    ])
    func malformedOrAmbiguousDocumentsFailWithoutPartialResults(json: String) {
        #expect(throws: ValidatedQuantityLexemes.Failure.invalidJSON) {
            try ValidatedQuantityLexemes.extract(from: Data(json.utf8))
        }
    }

    @Test
    func everyTruncatedPrefixIsRejected() {
        let bytes = Self.event("-123.450e+006")
        for end in 0..<bytes.count {
            #expect(throws: ValidatedQuantityLexemes.Failure.invalidJSON) {
                try ValidatedQuantityLexemes.extract(from: Data(bytes.prefix(end)))
            }
        }
    }

    @Test
    func invalidUTF8AndByteOrderMarkAreRejected() {
        let invalid = Data([0x7B, 0x22, 0x78, 0x22, 0x3A, 0x22, 0xFF, 0x22, 0x7D])
        for data in [invalid, Data([0xEF, 0xBB, 0xBF]) + Self.event("1")] {
            #expect(throws: ValidatedQuantityLexemes.Failure.invalidJSON) {
                try ValidatedQuantityLexemes.extract(from: data)
            }
        }
    }

    @Test
    func respectsAdmissionByteLimit() throws {
        let event = Self.event("1.000")
        let atLimit = event + Data(repeating: 0x20, count: ValidatedQuantityLexemes.maximumBytes - event.count)
        #expect(try ValidatedQuantityLexemes.extract(from: atLimit) == [0: "1.000"])
        #expect(throws: ValidatedQuantityLexemes.Failure.inputTooLarge) {
            try ValidatedQuantityLexemes.extract(from: atLimit + Data([0x20]))
        }
    }

    @Test
    func boundedNestingFailsClosed() throws {
        let allowed = "{\"other\":" + String(repeating: "[", count: ValidatedQuantityLexemes.maximumDepth - 1)
            + "0" + String(repeating: "]", count: ValidatedQuantityLexemes.maximumDepth - 1) + "}"
        #expect(try ValidatedQuantityLexemes.extract(from: Data(allowed.utf8)).isEmpty)
        let rejected = "{\"other\":" + String(repeating: "[", count: ValidatedQuantityLexemes.maximumDepth)
            + "0" + String(repeating: "]", count: ValidatedQuantityLexemes.maximumDepth) + "}"
        #expect(throws: ValidatedQuantityLexemes.Failure.nestingLimit) {
            try ValidatedQuantityLexemes.extract(from: Data(rejected.utf8))
        }
    }

    @Test
    func acceptsDataSlicesWithoutAssumingZeroBasedInputIndices() throws {
        let event = Self.event("80.000")
        let padded = Data([0x20]) + event + Data([0x20])
        #expect(try ValidatedQuantityLexemes.extract(from: padded[1..<(padded.count - 1)]) == [0: "80.000"])
    }
}


extension ValidatedQuantityLexemesTests {
    private static func event(_ token: String) -> Data {
        Data(#"{"entry":[{"resource":{"resourceType":"Observation","valueQuantity":{"value":\#(token)}}}]}"#.utf8)
    }
}
