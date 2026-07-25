//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import ModelsR4
import StudyPlatformAPIServer


extension ResourceProxy {
    init(_ schema: Components.Schemas.FHIRResource) throws {
        let data = try JSONEncoder().encode(schema)
        do {
            self = try JSONDecoder().decode(ResourceProxy.self, from: data)
        } catch {
            throw ServerError.badRequest("Invalid FHIR resource: \(error.localizedDescription)")
        }
    }
}


extension FHIRResourceRecord {
    convenience init(_ resource: ResourceProxy, participantID: UUID, receivedAt: Date = Date()) {
        let externalID = resource.get().id?.value?.string ?? UUID().uuidString

        guard case let .observation(observation) = resource else {
            self.init(
                participantID: participantID,
                resourceType: resource.resourceType,
                time: receivedAt,
                externalID: externalID,
                resource: resource
            )
            return
        }

        let coding = observation.code.coding?.first
        let quantity = observation.valueQuantity

        self.init(
            participantID: participantID,
            resourceType: resource.resourceType,
            time: observation.effectiveTime(default: receivedAt),
            externalID: externalID,
            resource: resource,
            code: coding?.code?.value?.string,
            codeSystem: coding?.system?.value?.url.absoluteString,
            value: quantity?.value?.value?.doubleValue,
            valueCode: quantity?.code?.value?.string,
            valueSystem: quantity?.system?.value?.url.absoluteString
        )
    }
}


extension ModelsR4.Observation {
    fileprivate var valueQuantity: Quantity? {
        if case let .quantity(quantity) = value {
            return quantity
        }
        return nil
    }

    fileprivate func effectiveTime(default fallback: Date) -> Date {
        switch effective {
        case .dateTime(let dateTime):
            return (try? dateTime.value?.asNSDate()) ?? fallback
        case .instant(let instant):
            return (try? instant.value?.asNSDate()) ?? fallback
        case .period(let period):
            return (try? period.start?.value?.asNSDate()) ?? fallback
        case .timing, .none:
            return fallback
        }
    }
}


extension FHIRDecimal {
    fileprivate var doubleValue: Double {
        NSDecimalNumber(decimal: decimal).doubleValue
    }
}
