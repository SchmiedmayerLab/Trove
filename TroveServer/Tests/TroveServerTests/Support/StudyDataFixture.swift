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
import TroveAPIServer
@testable import TroveServer
import Vapor


/// Retained synthetic FHIR records exercise the HTTP disclosure path. Official validator
/// and independent producer identity conformance remain separate acceptance evidence.
enum StudyDataFixture {
    static let reader = TestApp.Token.researcher(groups: ["/Test Group/researcher", "/Test Group/data-reader"])

    @discardableResult
    static func accept(
        _ fixture: ClinicalEventStoreTests.Fixture, on app: Application, sequence: UInt64 = 50, recordID: String? = nil, noteBytes: Int = 0
    ) async throws -> ValidatedExchangeEvent {
        let raw = try LocalPointEventFixture.bytes(
            source: fixture.source, sequence: sequence, recordID: recordID, fixtureURL: NativeIdentifierFixture.healthKitURL()
        )
        let system = try Components.Schemas.ParticipantSource(fixture.source).nativeRecordIdentifierSystem()
        let native = recordID == nil ? NativeIdentifierFixture.uuid : String(format: "00000000-0000-4000-8000-%012llx", sequence)
        var bytes = try NativeIdentifierFixture.adding([["system": system.rawValue, "value": native]], to: raw)
        if noteBytes > 0 { bytes = try addingNote(to: bytes, count: noteBytes) }
        let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-only")
        try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            _ = try await ClinicalEventStore(database: app.db).accept(
                event, sourceID: fixture.source.id, targets: fixture.targets(for: event), installation: fixture.installation
            )
        }
        return event
    }

    private static func addingNote(to bytes: Data, count: Int) throws -> Data {
        var document = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var entries = try #require(document["entry"] as? [[String: Any]])
        let index = try #require(entries.firstIndex { ($0["resource"] as? [String: Any])?["resourceType"] as? String == "Observation" })
        var resource = try #require(entries[index]["resource"] as? [String: Any])
        resource["note"] = [["text": String(repeating: "x", count: count)]]
        entries[index]["resource"] = resource
        document["entry"] = entries
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func retract(_ event: ValidatedExchangeEvent, fixture: ClinicalEventStoreTests.Fixture, on app: Application) async throws {
        let raw = try RetractionEventFixture.bytes(activeBytes: event.rawBytes)
        let retraction = try FHIRPointProjection.project(validatedBytes: raw, validatorIdentity: "test-only")
        try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            _ = try await ClinicalEventStore(database: app.db).accept(
                retraction, sourceID: fixture.source.id, targets: [], installation: fixture.installation
            )
        }
    }

    static func disclosureCount(on database: any Database) async throws -> Int {
        let sql = try #require(database as? any SQLDatabase)
        let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM audit_events WHERE action = 'study.data.disclosure'").first())
        return try row.decode(column: "count", as: Int.self)
    }

    static func rejectAudit(on database: any Database) async throws {
        let sql = try #require(database as? any SQLDatabase)
        if database is any PostgresDatabase {
            try await sql.raw("""
                CREATE TRIGGER reject_data_read BEFORE INSERT ON audit_events FOR EACH ROW
                WHEN (NEW.action = 'study.data.disclosure') EXECUTE FUNCTION trove_reject_audit_mutation()
                """)
                .run()
        } else {
            try await sql.raw("""
                CREATE TRIGGER reject_data_read BEFORE INSERT ON audit_events WHEN NEW.action = 'study.data.disclosure'
                BEGIN SELECT RAISE(ABORT, 'Synthetic disclosure insert failure'); END
                """)
                .run()
        }
    }

    static func resources(_ record: Components.Schemas.StudyDataRecord) throws -> [[String: Any]] {
        let bytes = try #require(Data(base64Encoded: record.bundleBase64))
        let bundle = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        return try #require(bundle["entry"] as? [[String: Any]]).compactMap { $0["resource"] as? [String: Any] }
    }
}
