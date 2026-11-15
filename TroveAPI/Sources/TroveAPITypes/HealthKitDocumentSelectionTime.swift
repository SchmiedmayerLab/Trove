// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import GroveFHIRContract
import ModelsR4


/// Explicit source document envelope time. It never substitutes a guessed clinical service period.
public struct HealthKitDocumentSelectionTime: Sendable {
    public enum Failure: Error { case invalidSourceTime }

    public let basis: CollectionTimeBasis
    /// Exact FHIR source period, retained for validation without a Date round trip.
    public let period: Period
    public let start: Date
    public let end: Date

    public init(entities: [ProvenanceEntity], expectedBasis: CollectionTimeBasis) throws {
        guard expectedBasis != .measurementTime else { throw Failure.invalidSourceTime }
        let values = entities.flatMap { entity in
            (entity.extension ?? []).filter { $0.url == HealthKitSourceDocumentTime.extensionURL }.map { (entity, $0) }
        }
        guard values.count == 1, let (entity, value) = values.first, entity.role.value == .source,
              entity.modifierExtension?.isEmpty != false, value.value == nil,
              let children = value.extension, children.count == 2,
              let basisValue = children.first(where: { $0.url.value?.url.absoluteString == "basis" }),
              let periodValue = children.first(where: { $0.url.value?.url.absoluteString == "period" }),
              basisValue.extension?.isEmpty != false, periodValue.extension?.isEmpty != false,
              case .code(let code) = basisValue.value, code.value?.string == expectedBasis.rawValue,
              case .period(let period) = periodValue.value,
              let start = period.start?.value, let end = period.end?.value,
              start.time != nil, end.time != nil, start.timeZone != nil, end.timeZone != nil else {
            throw Failure.invalidSourceTime
        }
        self.basis = expectedBasis
        self.period = period
        self.start = try start.asNSDate()
        self.end = try end.asNSDate()
        guard self.start.timeIntervalSince1970.isFinite, self.end.timeIntervalSince1970.isFinite, self.start <= self.end else {
            throw Failure.invalidSourceTime
        }
    }
}
