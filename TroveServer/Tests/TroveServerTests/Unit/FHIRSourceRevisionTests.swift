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


struct FHIRSourceRevisionTests {
    private static let url = "https://grovealliance.org/fhir/healthkit/StructureDefinition/healthkit-source-revision"

    @Test
    func sourceRevisionRetainsSourceFactsWithoutInventingAnApplicationAgent() throws {
        let value: [String: Any] = ["url": Self.url, "extension": [["url": "sourceName", "valueString": "Example Writer"]]]
        try FHIRPointSupportBoundary.validateExtensionLocations(in: Self.bundle(value))
    }

    @Test(arguments: ["url", "field", "reference", "duplicate", "nested", "location"])
    func sourceRevisionCannotCarryUnmodeledNestedContent(corruption: String) throws {
        var fact: [String: Any] = ["url": "sourceName", "valueString": "Example Writer"]
        switch corruption {
        case "field": fact["url"] = "unknown"
        case "reference":
            fact["valueString"] = nil
            fact["valueReference"] = ["reference": "Patient/other"]
        case "nested": fact["extension"] = [["url": "unexpected", "valueString": "extra"]]
        default: break
        }
        let value: [String: Any] = [
            "url": corruption == "url" ? "https://unexpected.test/extension" : Self.url,
            "extension": corruption == "duplicate" ? [fact, fact] : [fact]
        ]
        #expect { try FHIRPointSupportBoundary.validateExtensionLocations(in: Self.bundle(value, onEntity: corruption != "location")) }
            throws: { ($0 as? ServerError)?.status.code == 422 }
    }
}


extension FHIRSourceRevisionTests {
    private static func bundle(_ value: [String: Any], onEntity: Bool = true) throws -> Data {
        let extensions: [String: Any] = ["extension": [value]]
        var resource: [String: Any] = ["resourceType": "Provenance"]
        if onEntity {
            resource["entity"] = [extensions]
        } else {
            resource["extension"] = [value]
        }
        return try JSONSerialization.data(withJSONObject: ["resourceType": "Bundle", "entry": [["resource": resource]]])
    }
}
