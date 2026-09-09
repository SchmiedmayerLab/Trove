//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Vapor


/// Creates the current schema in a fresh primary database (`.psql`).
/// Development schema changes require recreating the database, not upgrading old rows.
func configurePostgresMigrations(for app: Application) {
    app.migrations.add(CreateGroups())
    app.migrations.add(CreateStudy())
    app.migrations.add(CreateComponents())
    app.migrations.add(CreateComponentSchedules())
    app.migrations.add(CreateStoredArtifacts())
    app.migrations.add(CreatePublishedStudies())
    app.migrations.add(CreateParticipants())
    app.migrations.add(CreateSourceBindings())
    app.migrations.add(CreateInvitationCodes())
    app.migrations.add(CreateEnrollments())
    app.migrations.add(CreateEnrollmentConsents())
    app.migrations.add(CreateAuditEvents())
    app.migrations.add(CreateClinicalEvents())
}
