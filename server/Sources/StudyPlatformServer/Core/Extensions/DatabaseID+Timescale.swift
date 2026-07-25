//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent


extension DatabaseID {
    /// Identifier for the TimescaleDB database connection used for FHIR resource hypertables.
    public static let timescale = DatabaseID(string: "timescale")
}
