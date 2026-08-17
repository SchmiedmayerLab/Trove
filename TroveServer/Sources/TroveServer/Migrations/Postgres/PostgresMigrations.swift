//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Vapor


/// Registers migrations targeting the primary PostgreSQL database (`.psql`).
func configurePostgresMigrations(for app: Application) {
    app.migrations.add(CreateGroups())
    app.migrations.add(CreateStudy())
    app.migrations.add(CreateComponents())
    app.migrations.add(CreateComponentSchedules())
    app.migrations.add(CreatePublishedStudies())
    app.migrations.add(CreateParticipants())
    app.migrations.add(CreateInvitationCodes())
    app.migrations.add(CreateEnrollments())
    app.migrations.add(CreateEnrollmentConsents())
}
