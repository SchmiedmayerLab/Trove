//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import ModelsR4


/// Extracts the original FHIR fraction before any floating-point display projection.
enum FHIRMeasurementInstant {
    static func exact(_ value: DateTime) throws -> RecordedInstant {
        guard value.time != nil, value.timeZone != nil else { throw FHIRValidationClient.invalid }
        return try RecordedInstant(Instant(value.description))
    }

    static func date(_ value: DateTime) throws -> Date {
        try exact(value).date
    }
}
