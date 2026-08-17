//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent


extension DatabaseID {
    /// Identifier for the TimescaleDB database connection used for FHIR resource hypertables.
    public static let timescale = DatabaseID(string: "timescale")
}
