//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import FluentPostgresDriver
import SQLKit
import Vapor


/// Serving credentials cannot act as the schema owner or reach protected data through another role.
/// Operators provision privileges; application startup only checks them.
enum DatabaseRuntimePrivileges {
    private static var unavailable: Abort {
        Abort(.internalServerError, reason: "Restricted database runtime credentials and protected schemas are required")
    }

    private static let validationQuery: SQLQueryString = """
            WITH reachable_roles AS (
                SELECT * FROM pg_catalog.pg_roles
                WHERE pg_catalog.pg_has_role(current_user, oid, 'MEMBER')
            ), protected_relations AS (
                SELECT c.oid, c.relname, n.nspname
                FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relkind IN ('r', 'p') AND n.nspname = 'public'
                    AND c.relname IN ('audit_events', '_fluent_migrations', 'published_studies', 'enrollment_consents', 'source_bindings',
                        'study_delegations', 'study_publication_candidates',
                        'clinical_events', 'clinical_source_records', 'clinical_record_events', 'clinical_output_bindings',
                        'clinical_output_retractions', 'clinical_questionnaire_contexts', 'clinical_point_derivations',
                        'clinical_event_nodes', 'clinical_point_facts', 'study_data_grants', 'clinical_attribution_commands')
            )
            SELECT
                (SELECT count(*) FROM protected_relations) = 18
                AND current_user = session_user
                AND NOT EXISTS (
                    SELECT 1 FROM pg_catalog.pg_auth_members membership
                    JOIN pg_catalog.pg_roles role ON role.oid = membership.member
                    WHERE role.rolname = current_user
                )
                AND EXISTS (SELECT 1 FROM reachable_roles)
                AND NOT EXISTS (
                    SELECT 1 FROM reachable_roles r
                    WHERE r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls
                        OR pg_catalog.has_database_privilege(r.oid, current_database(), 'CREATE,TEMPORARY')
                )
                AND NOT EXISTS (
                    SELECT 1 FROM pg_catalog.pg_database d JOIN reachable_roles r ON r.oid = d.datdba
                    WHERE d.datname = current_database()
                )
                AND NOT EXISTS (
                    SELECT 1 FROM pg_catalog.pg_namespace n CROSS JOIN reachable_roles r
                    WHERE n.nspname = 'public'
                        AND (n.nspowner = r.oid
                            OR pg_catalog.has_schema_privilege(r.oid, n.oid, 'CREATE'))
                )
                AND NOT EXISTS (
                    SELECT 1 FROM pg_catalog.pg_class c
                    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                    JOIN reachable_roles r ON r.oid = c.relowner
                    WHERE n.nspname = 'public'
                )
                AND NOT EXISTS (
                    SELECT 1 FROM pg_catalog.pg_proc p
                    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
                    JOIN reachable_roles r ON r.oid = p.proowner
                    WHERE n.nspname = 'public'
                )
                AND NOT EXISTS (
                    SELECT 1 FROM protected_relations p CROSS JOIN reachable_roles r
                    WHERE pg_catalog.has_table_privilege(r.oid, p.oid,
                        CASE WHEN p.relname = '_fluent_migrations'
                            THEN 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
                            ELSE 'UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN,SELECT WITH GRANT OPTION,INSERT WITH GRANT OPTION' END)
                        OR pg_catalog.has_any_column_privilege(r.oid, p.oid,
                            CASE WHEN p.relname = '_fluent_migrations' THEN 'SELECT,INSERT,UPDATE,REFERENCES'
                                WHEN p.relname IN ('source_bindings', 'study_delegations')
                                THEN 'REFERENCES,SELECT WITH GRANT OPTION,INSERT WITH GRANT OPTION,UPDATE WITH GRANT OPTION'
                                ELSE 'UPDATE,REFERENCES,SELECT WITH GRANT OPTION,INSERT WITH GRANT OPTION' END)
                        OR (p.relname IN ('source_bindings', 'study_delegations') AND EXISTS (
                            SELECT 1 FROM pg_catalog.pg_attribute column_info
                            WHERE column_info.attrelid = p.oid AND column_info.attnum > 0 AND NOT column_info.attisdropped
                                AND column_info.attname <> 'revoked_at'
                                AND pg_catalog.has_column_privilege(r.oid, p.oid, column_info.attnum, 'UPDATE')
                        ))
                ) AS allowed
            """

    static func validate(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw unavailable }
        if sql.dialect.name == "sqlite" {
            return // Explicit test fixture, never the production configuration.
        }
        guard database is any PostgresDatabase else { throw unavailable }
        do {
            let row = try await sql.raw(validationQuery).first()
            guard let row, try row.decode(column: "allowed", as: Bool.self) else { throw unavailable }
        } catch {
            throw unavailable
        }
    }
}
