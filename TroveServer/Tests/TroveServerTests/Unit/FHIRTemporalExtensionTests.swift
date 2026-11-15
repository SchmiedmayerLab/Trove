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


struct FHIRTemporalExtensionTests {
    private static let timezone = ["url": "http://hl7.org/fhir/StructureDefinition/timezone", "valueCode": "Europe/Berlin"]

    @Test(arguments: ["_effectiveDateTime", "_issued", "_authored", "_occurredDateTime", "effectivePeriod", "occurredPeriod"])
    func acceptsTimezoneOnlyOnTemporalPrimitives(field: String) throws {
        var resource: [String: Any] = ["resourceType": "Observation"]
        let primitive: [String: Any] = ["extension": [Self.timezone]]
        resource[field] = field.hasSuffix("Period") ? ["_start": primitive, "_end": primitive] : primitive
        try FHIRPointSupportBoundary.validateExtensionLocations(in: Self.bundle(resource))
    }

    @Test(arguments: ["url", "reference", "nested", "modifier", "duplicate", "quantity", "value-metadata", "extra-field"])
    func unrelatedNestedPayloadCannotHideBehindATimezone(corruption: String) throws {
        var item: [String: Any] = Self.timezone
        switch corruption {
        case "url": item["url"] = "https://unexpected.test/extension"
        case "reference":
            item.removeValue(forKey: "valueCode")
            item["valueReference"] = ["reference": "Patient/other"]
        case "nested": item["extension"] = [Self.timezone]
        case "modifier": item["modifierExtension"] = [Self.timezone]
        case "value-metadata": item["_valueCode"] = ["extension": [Self.timezone]]
        case "extra-field": item["unexpected"] = "source-specific"
        default: break
        }
        let values = corruption == "duplicate" ? [item, item] : [item]
        let primitive: [String: Any] = ["extension": values]
        let field = corruption == "quantity" ? "valueQuantity" : "_effectiveDateTime"
        let resource: [String: Any] = ["resourceType": "Observation", field: primitive]
        #expect { try FHIRPointSupportBoundary.validateExtensionLocations(in: Self.bundle(resource)) }
            throws: { ($0 as? ServerError)?.status.code == 422 }
    }

    @Test
    func modifierExtensionsOnThePrimitiveRemainUnsupported() throws {
        let resource: [String: Any] = [
            "resourceType": "Observation", "_effectiveDateTime": ["modifierExtension": [Self.timezone]]
        ]
        #expect { try FHIRPointSupportBoundary.validateExtensionLocations(in: Self.bundle(resource)) }
            throws: { ($0 as? ServerError)?.status.code == 422 }
    }
}


extension FHIRTemporalExtensionTests {
    private static func bundle(_ resource: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["resourceType": "Bundle", "entry": [["resource": resource]]])
    }
}
