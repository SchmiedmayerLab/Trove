//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Vapor


/// Registers migrations targeting the TimescaleDB instance (`.timescale`).
func configureTimescaleMigrations(for app: Application) {
    app.migrations.add(CreateFHIRResources(), to: .timescale)
}
