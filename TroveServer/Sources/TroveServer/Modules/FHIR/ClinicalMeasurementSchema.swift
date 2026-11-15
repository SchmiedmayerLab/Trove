//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import FluentSQL


/// Canonical decimal fractions allow exact comparisons in either supported database.
enum ClinicalMeasurementSchema {
    static func fields(_ builder: SchemaBuilder) -> SchemaBuilder {
        builder
            .field("effective_seconds", .int64, .required)
            .field("effective_fraction", .string, .required, fraction("effective_fraction"))
            .field("effective_end_seconds", .int64)
            .field("effective_end_fraction", .string, fraction("effective_end_fraction"), .sql(unsafeRaw: """
                CHECK ((effective_end_seconds IS NULL) = (effective_end_fraction IS NULL))
                """))
    }

    static func fraction(_ column: String) -> DatabaseSchema.FieldConstraint {
        let nonDigit = "0123456789".reduce(into: column) { $0 = "replace(\($0), '\($1)', '')" }
        return .sql(unsafeRaw: """
            CHECK (length(\(column)) <= 4096 AND length(\(nonDigit)) = 0
                AND (length(\(column)) = 0 OR substr(\(column), length(\(column)), 1) <> '0'))
            """)
    }
}
