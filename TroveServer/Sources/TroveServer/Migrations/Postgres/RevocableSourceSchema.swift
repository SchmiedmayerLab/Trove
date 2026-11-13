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


/// Source and installation identities retain history and permit only irreversible revocation.
enum RevocableSourceSchema {
    static func protect(table: String, immutableColumns: [String], on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        let postgres = database is any PostgresDatabase
        let differs = postgres ? "IS DISTINCT FROM" : "IS NOT"
        // Names are fixed migration declarations, never values from a request.
        let changed = immutableColumns.map { "NEW.\($0) \(differs) OLD.\($0)" }.joined(separator: " OR ")
        let condition = "(\(changed)) OR (OLD.revoked_at IS NOT NULL AND NEW.revoked_at \(differs) OLD.revoked_at)"
        if postgres {
            try await protectPostgres(table: table, condition: condition, on: sql)
        } else {
            try await sql.raw("""
                CREATE TRIGGER \(ident: table + "_identity") BEFORE UPDATE ON \(ident: table)
                WHEN \(unsafeRaw: condition)
                BEGIN SELECT RAISE(ABORT, 'Source identity and revocation are immutable'); END
                """)
                .run()
            try await sql.raw("""
                CREATE TRIGGER \(ident: table + "_no_removal") BEFORE DELETE ON \(ident: table)
                BEGIN SELECT RAISE(ABORT, 'Source identity history is retained'); END
                """)
                .run()
        }
    }

    private static func protectPostgres(table: String, condition: String, on sql: any SQLDatabase) async throws {
        let function = "trove_protect_" + table
        try await sql.raw("""
            CREATE FUNCTION \(ident: function)() RETURNS trigger AS $$
            BEGIN
                IF TG_OP <> 'UPDATE' THEN
                    RAISE EXCEPTION 'Source identity history is retained' USING ERRCODE = '23514';
                END IF;
                IF \(unsafeRaw: condition) THEN
                    RAISE EXCEPTION 'Source identity and revocation are immutable' USING ERRCODE = '23514';
                END IF;
                RETURN NEW;
            END;
            $$ LANGUAGE plpgsql
            """)
            .run()
        try await sql.raw("""
            CREATE TRIGGER \(ident: table + "_identity") BEFORE UPDATE ON \(ident: table)
            FOR EACH ROW EXECUTE FUNCTION \(ident: function)()
            """)
            .run()
        try await sql.raw("""
            CREATE TRIGGER \(ident: table + "_no_removal") BEFORE DELETE OR TRUNCATE ON \(ident: table)
            FOR EACH STATEMENT EXECUTE FUNCTION \(ident: function)()
            """)
            .run()
    }
}
