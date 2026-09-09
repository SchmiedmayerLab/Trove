//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import FluentPostgresDriver
import Foundation
import SQLKit
import Testing
@testable import TroveServer
import Vapor


@Suite(.enabled(if: Environment.get("TROVE_TEST_POSTGRES_PORT") != nil, "Requires an isolated PostgreSQL test database"))
struct DatabaseRuntimePrivilegesTests {
    private struct RuntimeFixture: Sendable {
        let database: any Database
        let operatorDatabase: any Database
        let admin: any SQLDatabase
        let role: String
        let databaseName: String
    }

    @Test
    func minimallyPrivilegedActualLoginIsAccepted() async throws {
        try await Self.withRuntime { fixture in
            let sql = try #require(fixture.database as? any SQLDatabase)
            let result = try await sql.raw("SELECT current_user::text AS effective, session_user::text AS authenticated").first()
            let row = try #require(result)
            #expect(try row.decode(column: "effective", as: String.self) == fixture.role)
            #expect(try row.decode(column: "authenticated", as: String.self) == fixture.role)
            try await DatabaseRuntimePrivileges.validate(on: fixture.database)
            let groups = try await Group.query(on: fixture.database).count()
            #expect(groups == 0)
            let event = AuditEvent(
                context: .init(actor: .init(issuer: "https://identity.example/realm", subject: "runtime-participant")),
                action: .sourceRegistered,
                scope: .participantSource(participantID: UUID(), sourceBindingID: UUID()),
                target: .init(id: UUID())
            )
            _ = try await fixture.database.transaction { transaction in
                try await AuditRepository.recordMutation(event, on: transaction)
            }
            let retained = try #require(try await sql.raw("SELECT scope_kind FROM audit_events WHERE id = \(bind: event.id)").first())
            #expect(try retained.decode(column: "scope_kind", as: String.self) == "participant_source")
        }
    }

    @Test
    func databaseOwnerIsRejected() async throws {
        try await TestApp.withApp { app, _ in
            await Self.expectRejected(on: app.db)
        }
    }

    @Test(arguments: [
        "UPDATE published_studies SET bundle_digest = bundle_digest WHERE false",
        "DELETE FROM published_studies WHERE false", "TRUNCATE published_studies",
        "UPDATE enrollment_consents SET evidence_digest = evidence_digest WHERE false",
        "DELETE FROM enrollment_consents WHERE false", "TRUNCATE enrollment_consents",
        "UPDATE source_bindings SET participant_id = participant_id WHERE false",
        "DELETE FROM source_bindings WHERE false", "TRUNCATE source_bindings",
        "UPDATE clinical_events SET raw_sha256 = raw_sha256 WHERE false", "DELETE FROM clinical_events WHERE false", "TRUNCATE clinical_events",
        "UPDATE clinical_event_nodes SET ordinal = ordinal WHERE false",
        "DELETE FROM clinical_event_nodes WHERE false", "TRUNCATE clinical_event_nodes",
        "UPDATE clinical_point_facts SET quantity_value = quantity_value WHERE false",
        "DELETE FROM clinical_point_facts WHERE false", "TRUNCATE clinical_point_facts",
        "UPDATE study_data_grants SET consent_id = consent_id WHERE false", "DELETE FROM study_data_grants WHERE false", "TRUNCATE study_data_grants",
        "UPDATE clinical_source_records SET identifier_value = identifier_value WHERE false",
        "DELETE FROM clinical_record_events WHERE false", "TRUNCATE clinical_output_bindings",
        "UPDATE clinical_output_retractions SET kind = kind WHERE false", "TRUNCATE clinical_output_retractions",
        "DELETE FROM clinical_questionnaire_contexts WHERE false", "TRUNCATE clinical_point_derivations",
        "UPDATE clinical_attribution_commands SET target_intent = target_intent WHERE false",
        "DELETE FROM clinical_attribution_commands WHERE false", "TRUNCATE clinical_attribution_commands",
        "SELECT name FROM _fluent_migrations"
    ])
    func actualRuntimeCannotMutateProtectedRecords(statement: String) async throws {
        try await Self.withRuntime { fixture in
            let sql = try #require(fixture.database as? any SQLDatabase)
            await #expect {
                try await sql.raw(SQLQueryString(statement)).run()
            } throws: { ($0 as? PSQLError)?.serverInfo?[.sqlState] == "42501" }
        }
    }

    @Test
    func actualRuntimeCanAppendEvidenceAndRevokeSource() async throws {
        try await Self.withRuntime { fixture in
            let group = try await GroupFixtures.createGroup(on: fixture.database)
            let study = try await StudyFixtures.createStudy(on: fixture.database, groupId: group.requireId())
            let publication = try await PublishedStudyFixtures.createPublishedStudy(on: fixture.database, studyId: study.requireId())
            #expect(try await PublishedStudy.find(publication.requireId(), on: fixture.database)?.bundleDigest == publication.bundleDigest)
            let participant = try await ParticipantFixtures.createParticipant(on: fixture.database)
            let enrollment = Enrollment(participantId: try participant.requireId(), studyId: try study.requireId(), currentRevision: 1)
            try await enrollment.save(on: fixture.database)
            let consent = try await RetainedRecordFixtures.consent(on: fixture.database, enrollmentID: enrollment.requireId())
            try await consent.save(on: fixture.database)
            #expect(try await EnrollmentConsent.find(consent.requireId(), on: fixture.database)?.commandID == consent.commandID)
            let id = UUID()
            let sql = try #require(fixture.database as? any SQLDatabase)
            try await sql.raw("""
                INSERT INTO source_bindings (
                    id, participant_id, registration_id, kind, event_identifier_system,
                    participant_identifier_system, participant_identifier_value, created_at
                ) VALUES (
                    \(bind: id), \(bind: participant.requireId()), \(bind: UUID()), 'participant-app',
                    'https://example.invalid/source', 'https://example.invalid/participant', 'synthetic', CURRENT_TIMESTAMP
                )
                """)
                .run()
            try await sql.raw("UPDATE source_bindings SET revoked_at = CURRENT_TIMESTAMP WHERE id = \(bind: id)").run()
            let row = try #require(try await sql.raw("SELECT participant_id, revoked_at FROM source_bindings WHERE id = \(bind: id)").first())
            #expect(try row.decode(column: "participant_id", as: UUID.self) == participant.requireId())
            #expect(try row.decode(column: "revoked_at", as: Date?.self) != nil)
            try await Self.appendClinicalRows(on: sql, sourceID: id, publication: publication, consent: consent, enrollment: enrollment)
            try await DatabaseRuntimePrivileges.validate(on: fixture.database)
        }
    }

    @Test
    func ownerSessionCannotMasqueradeAsRuntimeThroughSetRole() async throws {
        try await Self.withRuntime { fixture in
            try await fixture.operatorDatabase.transaction { transaction in
                let sql = try #require(transaction as? any SQLDatabase)
                try await sql.raw("SET LOCAL ROLE \(ident: fixture.role)").run()
                await Self.expectRejected(on: transaction)
            }
        }
    }

    @Test(arguments: ["pg_read_server_files", "pg_execute_server_program"])
    func predefinedOperatingSystemRolesAreRejected(group: String) async throws {
        try await Self.withRuntime { fixture in
            // Inspect privilege rejection only; never exercise filesystem or process capabilities.
            try await fixture.admin.raw("GRANT \(ident: group) TO \(ident: fixture.role)").run()
            await Self.expectRejected(on: fixture.database)
        }
    }

    @Test(arguments: ["SUPERUSER", "CREATEDB", "CREATEROLE", "REPLICATION", "BYPASSRLS"])
    func privilegedLoginFlagsAreRejected(flag: String) async throws {
        try await Self.withRuntime { fixture in
            try await fixture.admin.raw("ALTER ROLE \(ident: fixture.role) \(unsafeRaw: flag)").run()
            await Self.expectRejected(on: fixture.database)
        }
    }

    @Test(arguments: [
        "UPDATE ON public.audit_events", "DELETE ON public.audit_events", "TRUNCATE ON public.audit_events",
        "UPDATE (outcome) ON public.audit_events", "INSERT ON public._fluent_migrations",
        "UPDATE (name) ON public._fluent_migrations", "CREATE ON SCHEMA public", "MAINTAIN ON public.audit_events",
        "MAINTAIN ON public._fluent_migrations", "SELECT ON public._fluent_migrations",
        "SELECT (name) ON public._fluent_migrations", "UPDATE ON public.published_studies",
        "DELETE ON public.enrollment_consents", "TRUNCATE ON public.published_studies",
        "MAINTAIN ON public.enrollment_consents", "UPDATE (bundle_digest) ON public.published_studies",
        "UPDATE (evidence_digest) ON public.enrollment_consents", "UPDATE ON public.source_bindings",
        "DELETE ON public.source_bindings", "TRUNCATE ON public.source_bindings", "MAINTAIN ON public.source_bindings",
        "UPDATE (participant_id) ON public.source_bindings",
        "UPDATE ON public.clinical_events", "DELETE ON public.clinical_event_nodes",
        "TRUNCATE ON public.clinical_point_facts", "MAINTAIN ON public.study_data_grants",
        "UPDATE (raw_sha256) ON public.clinical_events", "UPDATE (ordinal) ON public.clinical_event_nodes",
        "UPDATE (quantity_value) ON public.clinical_point_facts", "UPDATE (consent_id) ON public.study_data_grants",
        "UPDATE (identifier_value) ON public.clinical_source_records", "DELETE ON public.clinical_record_events",
        "UPDATE ON public.clinical_attribution_commands",
        "TRUNCATE ON public.clinical_output_bindings", "UPDATE ON public.clinical_output_retractions",
        "UPDATE ON public.clinical_questionnaire_contexts", "DELETE ON public.clinical_point_derivations"
    ])
    func excessiveDirectPrivilegesAreRejected(grant: String) async throws {
        try await Self.withRuntime { fixture in
            try await fixture.admin.raw("GRANT \(unsafeRaw: grant) TO \(ident: fixture.role)").run()
            await Self.expectRejected(on: fixture.database)
        }
    }

    @Test(arguments: [
        "SELECT ON public.audit_events", "INSERT ON public.audit_events", "SELECT ON public._fluent_migrations",
        "SELECT (actor_subject) ON public.audit_events", "INSERT (actor_subject) ON public.audit_events",
        "SELECT (name) ON public._fluent_migrations", "SELECT ON public.published_studies",
        "INSERT ON public.enrollment_consents", "SELECT (bundle_digest) ON public.published_studies",
        "INSERT (evidence_digest) ON public.enrollment_consents", "UPDATE (revoked_at) ON public.source_bindings",
        "SELECT ON public.source_bindings", "INSERT (participant_id) ON public.source_bindings",
        "SELECT ON public.clinical_events", "INSERT ON public.clinical_event_nodes",
        "SELECT (quantity_value) ON public.clinical_point_facts", "INSERT (consent_id) ON public.study_data_grants",
        "INSERT ON public.clinical_source_records", "SELECT ON public.clinical_record_events", "INSERT ON public.clinical_output_bindings",
        "INSERT ON public.clinical_output_retractions",
        "INSERT ON public.clinical_questionnaire_contexts", "INSERT ON public.clinical_point_derivations",
        "INSERT ON public.clinical_attribution_commands"
    ])
    func protectedAccessCannotBeDelegated(grant: String) async throws {
        try await Self.withRuntime { fixture in
            try await fixture.admin.raw("GRANT \(unsafeRaw: grant) TO \(ident: fixture.role) WITH GRANT OPTION").run()
            await Self.expectRejected(on: fixture.database)
        }
    }

    @Test(arguments: ["CREATE", "TEMPORARY"])
    func databaseObjectCreationIsRejected(privilege: String) async throws {
        try await Self.withRuntime { fixture in
            try await fixture.admin.raw("GRANT \(unsafeRaw: privilege) ON DATABASE \(ident: fixture.databaseName) TO \(ident: fixture.role)").run()
            await Self.expectRejected(on: fixture.database)
        }
    }

    @Test(arguments: [
        "UPDATE ON public.audit_events", "INSERT ON public._fluent_migrations",
        "UPDATE (actor_subject) ON public.audit_events", "CREATE ON SCHEMA public",
        "UPDATE (bundle_digest) ON public.published_studies", "DELETE ON public.enrollment_consents",
        "UPDATE (participant_id) ON public.source_bindings",
        "UPDATE (raw_sha256) ON public.clinical_events", "DELETE ON public.clinical_event_nodes",
        "UPDATE (quantity_value) ON public.clinical_point_facts", "TRUNCATE ON public.study_data_grants"
    ])
    func excessivePublicGrantsAreRejected(grant: String) async throws {
        try await Self.withRuntime { fixture in
            // Only this generated database is affected; TestApp removes it after the test.
            try await fixture.admin.raw("GRANT \(unsafeRaw: grant) TO PUBLIC").run()
            await Self.expectRejected(on: fixture.database)
        }
    }

    @Test(arguments: [true, false])
    func reachableGroupPrivilegesAreRejectedEvenWithoutInheritance(inherit: Bool) async throws {
        try await Self.withRuntime { fixture in
            try await Self.withGroup(on: fixture) { group in
                try await fixture.admin.raw("GRANT CREATE ON SCHEMA public TO \(ident: group)").run()
                try await fixture.admin.raw("""
                    GRANT \(ident: group) TO \(ident: fixture.role) WITH INHERIT \(unsafeRaw: inherit ? "TRUE" : "FALSE"), SET TRUE
                    """)
                    .run()
                await Self.expectRejected(on: fixture.database)
            }
        }
    }

    @Test(arguments: ["audit_events", "clinical_events", "clinical_event_nodes", "clinical_point_facts", "study_data_grants"])
    func indirectOwnershipThroughNonInheritedGroupIsRejected(table: String) async throws {
        try await Self.withRuntime { fixture in
            try await Self.withGroup(on: fixture) { group in
                try await fixture.admin.raw("GRANT \(ident: group) TO \(ident: fixture.role) WITH INHERIT FALSE, SET TRUE").run()
                // Ownership bypasses an otherwise restrictive table ACL.
                try await fixture.admin.raw("ALTER TABLE public.\(ident: table) OWNER TO \(ident: group)").run()
                await Self.expectRejected(on: fixture.database)
                try await fixture.admin.raw("ALTER TABLE public.\(ident: table) OWNER TO CURRENT_USER").run()
            }
        }
    }

    @Test(arguments: [
        "public.audit_events", "public._fluent_migrations", "public.published_studies",
        "public.enrollment_consents", "public.source_bindings", "public.clinical_events",
        "public.clinical_event_nodes", "public.clinical_point_facts", "public.study_data_grants",
        "public.clinical_source_records", "public.clinical_record_events", "public.clinical_output_bindings", "public.clinical_output_retractions",
        "public.clinical_questionnaire_contexts", "public.clinical_point_derivations",
        "public.clinical_attribution_commands"
    ])
    func absentProtectedTablesFailClosed(table: String) async throws {
        try await Self.withRuntime { fixture in
            // Rename rather than delete: retain all history and restore schema on database cleanup.
            try await fixture.admin.raw("ALTER TABLE \(unsafeRaw: table) RENAME TO runtime_test_hidden").run()
            await Self.expectRejected(on: fixture.database)
            let parts = table.split(separator: ".").map(String.init)
            try await fixture.admin.raw("ALTER TABLE \(ident: parts[0]).runtime_test_hidden RENAME TO \(ident: parts[1])").run()
        }
    }
}


extension DatabaseRuntimePrivilegesTests {
    private static func expectRejected(on database: any Database) async {
        await #expect {
            try await DatabaseRuntimePrivileges.validate(on: database)
        } throws: { error in
            guard let abort = error as? Abort else {
                return false
            }
            return abort.status == .internalServerError && !abort.reason.contains("trove_runtime_test_")
        }
    }

    private static func withRuntime(_ body: @escaping @Sendable (RuntimeFixture) async throws -> Void) async throws {
        try await TestApp.withApp { app, _ in
            let admin = try #require(app.db as? any SQLDatabase)
            let result = try await admin.raw("SELECT current_database() AS name").first()
            let databaseName = try #require(result).decode(column: "name", as: String.self)
            let role = "trove_runtime_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let password = UUID().uuidString
            try await Self.createLogin(role: role, password: password, on: admin)
            do {
                try await Self.grantRuntime(role: role, databaseName: databaseName, on: admin)
                try await Self.withLogin(role: role, password: password, databaseName: databaseName) { database in
                    try await body(.init(database: database, operatorDatabase: app.db, admin: admin, role: role, databaseName: databaseName))
                }
            } catch {
                try await Self.removeRole(role, databaseName: databaseName, on: admin)
                throw error
            }
            try await Self.removeRole(role, databaseName: databaseName, on: admin)
        }
    }

    private static func createLogin(role: String, password: String, on sql: any SQLDatabase) async throws {
        do {
            try await sql.raw("CREATE ROLE \(ident: role) LOGIN PASSWORD \(literal: password)").run()
        } catch {
            // Never let a failed utility query print even this disposable fixture credential.
            throw Abort(.internalServerError, reason: "Isolated runtime login creation failed")
        }
    }

    private static func grantRuntime(role: String, databaseName: String, on sql: any SQLDatabase) async throws {
        try await sql.raw("REVOKE TEMPORARY ON DATABASE \(ident: databaseName) FROM PUBLIC").run()
        try await sql.raw("GRANT CONNECT ON DATABASE \(ident: databaseName) TO \(ident: role)").run()
        try await sql.raw("GRANT USAGE ON SCHEMA public TO \(ident: role)").run()
        try await sql.raw("""
            GRANT SELECT, INSERT, UPDATE, DELETE ON public.groups, public.studies, public.components,
                public.component_schedules, public.participants, public.invitation_codes,
                public.enrollments, public.stored_artifacts TO \(ident: role)
            """)
            .run()
        try await sql.raw("""
            GRANT SELECT, INSERT ON public.audit_events, public.published_studies,
                public.enrollment_consents, public.source_bindings, public.clinical_events,
                public.clinical_event_nodes, public.clinical_point_facts, public.study_data_grants,
                public.clinical_source_records, public.clinical_record_events, public.clinical_output_bindings,
                public.clinical_output_retractions,
                public.clinical_questionnaire_contexts, public.clinical_point_derivations,
                public.clinical_attribution_commands TO \(ident: role)
            """)
            .run()
        try await sql.raw("GRANT UPDATE (revoked_at) ON public.source_bindings TO \(ident: role)").run()
    }

    /// SQL-role capability fixture, not a bypass of the production receiver's validation/authority checks.
    private static func appendClinicalRows(
        on sql: any SQLDatabase, sourceID: UUID, publication: PublishedStudy, consent: EnrollmentConsent, enrollment: Enrollment
    ) async throws {
        let eventID = UUID()
        let nodeID = UUID()
        try await sql.raw("""
            INSERT INTO clinical_events (id, source_id, identifier_system, identifier_value, raw_bytes, raw_sha256,
                validator_identity, target_intent, received_at, node_count)
            VALUES (\(bind: eventID), \(bind: sourceID), 'urn:runtime-fixture:event', '1', \(bind: Data("synthetic".utf8)),
                \(bind: String(repeating: "a", count: 64)), 'role-test', '[]', CURRENT_TIMESTAMP, 1)
            """)
            .run()
        try await sql.raw("""
            INSERT INTO clinical_event_nodes (id, event_id, source_id, full_url, ordinal, resource_type)
            VALUES (\(bind: nodeID), \(bind: eventID), \(bind: sourceID), 'urn:runtime-fixture:point', 0, 'Observation')
            """)
            .run()
        let (recordID, bindingID) = try await appendRecordIdentity(on: sql, sourceID: sourceID, eventID: eventID)
        try await sql.raw("""
            INSERT INTO clinical_point_facts (node_id, source_id, event_id, record_id, output_binding_id, profile, effective_at,
                quantity_value, quantity_system, quantity_code, code_system, code)
            VALUES (\(bind: nodeID), \(bind: sourceID), \(bind: eventID), \(bind: recordID), \(bind: bindingID),
                \(bind: CollectionRequirement.supportedProfile), CURRENT_TIMESTAMP, '72',
                'http://unitsofmeasure.org', '/min', 'http://loinc.org', '8867-4')
            """)
            .run()
        try await sql.raw("""
            INSERT INTO study_data_grants (id, node_id, source_id, participant_id, study_id, enrollment_id,
                consent_id, publication_id, revision, accepted_at)
            VALUES (\(bind: UUID()), \(bind: nodeID), \(bind: sourceID), \(bind: enrollment.$participant.id),
                \(bind: publication.$study.id), \(bind: enrollment.requireID()),
                \(bind: consent.requireID()), \(bind: publication.requireID()), \(bind: publication.revision), CURRENT_TIMESTAMP)
            """)
            .run()
        for table in ["clinical_events", "clinical_event_nodes", "clinical_point_facts", "study_data_grants"] {
            let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM \(ident: table)").first())
            #expect(try row.decode(column: "count", as: Int.self) == 1)
        }
    }

    private static func appendRecordIdentity(on sql: any SQLDatabase, sourceID: UUID, eventID: UUID) async throws -> (UUID, UUID) {
        let recordID = UUID()
        let bindingID = UUID()
        try await sql.raw("""
            INSERT INTO clinical_source_records (id, source_id, identifier_system, identifier_value)
            VALUES (\(bind: recordID), \(bind: sourceID), 'urn:runtime-fixture:source', '1')
            """)
            .run()
        try await sql.raw("""
            INSERT INTO clinical_record_events (event_id, source_id, record_id, kind)
            VALUES (\(bind: eventID), \(bind: sourceID), \(bind: recordID), 'active')
            """)
            .run()
        try await sql.raw("""
            INSERT INTO clinical_output_bindings (id, source_id, record_id, first_event_id, identifier_system, identifier_value)
            VALUES (\(bind: bindingID), \(bind: sourceID), \(bind: recordID), \(bind: eventID), 'urn:runtime-fixture:output', '1')
            """)
            .run()
        return (recordID, bindingID)
    }

    private static func withLogin(
        role: String,
        password: String,
        databaseName: String,
        _ body: @Sendable (any Database) async throws -> Void
    ) async throws {
        let rawPort = try #require(Environment.get("TROVE_TEST_POSTGRES_PORT"))
        let port = try #require(Int(rawPort))
        try #require((1024...65535).contains(port))
        let app = try await Application.make(.testing)
        do {
            let configuration = SQLPostgresConfiguration(
                hostname: "127.0.0.1", port: port, username: role, password: password, database: databaseName, tls: .disable
            )
            app.databases.use(.postgres(configuration: configuration), as: .psql, isDefault: true)
            try await body(app.db)
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    private static func removeRole(_ role: String, databaseName: String, on sql: any SQLDatabase) async throws {
        // Exact generated role, in its disposable database only. Ownership tests restore their
        // table owner first. DROP OWNED also removes column ACLs that table-level REVOKE misses.
        let result = try await sql.raw("SELECT current_database() AS name").first()
        let currentDatabase = try #require(result).decode(column: "name", as: String.self)
        try #require(currentDatabase == databaseName && currentDatabase.hasPrefix("trove_test_"))
        try #require(role.hasPrefix("trove_runtime_test_"))
        try await sql.raw("DROP OWNED BY \(ident: role)").run()
        try await sql.raw("DROP ROLE \(ident: role)").run()
    }

    private static func withGroup(on fixture: RuntimeFixture, _ body: (String) async throws -> Void) async throws {
        let group = "trove_runtime_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try await fixture.admin.raw("CREATE ROLE \(ident: group) NOLOGIN").run()
        do {
            try await body(group)
        } catch {
            try await removeRole(group, databaseName: fixture.databaseName, on: fixture.admin)
            throw error
        }
        try await removeRole(group, databaseName: fixture.databaseName, on: fixture.admin)
    }
}
