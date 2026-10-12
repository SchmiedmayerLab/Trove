//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import Foundation
import GroveFHIRContract
import GroveLocalization
import SQLKit
import Testing
import TroveAPIServer
@testable import TroveServer
import Vapor


/// Storage/authority tests use synthetic admitted projections, not a substitute for IG-validator tests.
/// Publication, enrollment, consent acceptance, and source registration all use production services.
struct ClinicalEventStoreTests {
    private struct InvalidEventRow {
        let identifier: String
        let digest: String
        let count: Int
        let bytes: Data
    }

    struct Fixture: Sendable {
        let source: SourceBinding
        let studyIDs: [UUID]
        let enrollmentIDs: [UUID]
        let consentIDs: [UUID]

        var targets: [ClinicalEventTarget] {
            consentIDs.map { .init(consentID: $0, outputFullURLs: ["urn:uuid:point"]) }
        }

        func targets(for event: ValidatedExchangeEvent, studies: [Int] = [0, 1]) -> [ClinicalEventTarget] {
            studies.map { .init(consentID: consentIDs[$0], outputFullURLs: event.outputs.map(\.fullURL)) }
        }
    }

    @Test(arguments: GroveIdentifierRole.allCases)
    func rejectsForeignDeploymentNamespacesBeforePersisting(role: GroveIdentifierRole) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await Self.prepare(on: app)
            var event = Self.event(source: fixture.source)
            event.deploymentIdentifiers.systems[role] = ["https://foreign.example/identity"]
            let candidate = event
            try await AuthContext.$current.withValue(Self.participant) {
                await #expect {
                    try await ClinicalEventStore(database: app.db).accept(candidate, sourceID: fixture.source.id, targets: fixture.targets)
                } throws: { ($0 as? ServerError)?.status.code == 403 }
                try await Self.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
            }
        }
    }

    @Test
    func onePayloadHasTwoIndependentGrantsAndWithdrawalDoesNotRewriteHistory() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await Self.prepare(on: app)
            try await AuthContext.$current.withValue(Self.participant) {
                let store = ClinicalEventStore(database: app.db)
                let event = Self.event(source: fixture.source)
                async let first = store.accept(event, sourceID: fixture.source.id, targets: fixture.targets)
                async let concurrentRetry = store.accept(event, sourceID: fixture.source.id, targets: fixture.targets)
                let (receipt, sameReceipt) = try await (first, concurrentRetry)
                #expect(receipt == sameReceipt)
                #expect(receipt.nodeCount == 2)
                #expect(receipt.producerEventIdentifier == .init(system: event.eventIdentifierSystem, value: event.eventIdentifierValue))
                #expect(receipt.payloadSHA256 == SHA256.hash(data: event.rawBytes).map { String(format: "%02x", $0) }.joined())
                try await Self.expectRows(events: 1, nodes: 2, facts: 1, grants: 2, on: app.db)
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 1)
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[1]) == 1)
                _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: fixture.enrollmentIDs[0])
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == 0)
                #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[1]) == 1)
                let reloaded = ClinicalEventStore(database: app.db)
                let retry = try await reloaded.accept(event, sourceID: fixture.source.id, targets: fixture.targets.reversed())
                #expect(retry == receipt)
                try await Self.expectRows(events: 1, nodes: 2, facts: 1, grants: 2, on: app.db)
                let sql = try #require(app.db as? any SQLDatabase)
                let row = try #require(try await sql.raw("SELECT raw_bytes FROM clinical_events").first())
                #expect(try row.decode(column: "raw_bytes", as: Data.self) == event.rawBytes)
                let fact = try #require(try await sql.raw("SELECT quantity_value FROM clinical_point_facts").first())
                #expect(try fact.decode(column: "quantity_value", as: String.self) == "72.12345678901234567890123456789")
                let audit = try #require(try await sql.raw("""
                    SELECT COUNT(*) AS count, COUNT(DISTINCT correlation_id) AS invocation_count
                    FROM audit_events WHERE action IN ('clinical.event.accepted', 'study.data.granted')
                    """)
                    .first())
                #expect(try audit.decode(column: "count", as: Int.self) == 3)
                #expect(try audit.decode(column: "invocation_count", as: Int.self) == 1)
            }
        }
    }

    @Test(arguments: ["bytes", "targets", "revoked-source"])
    func retriesCannotChangeCustodyOrBroadenTargets(change: String) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await Self.prepare(on: app)
            try await AuthContext.$current.withValue(Self.participant) {
                let store = ClinicalEventStore(database: app.db)
                let outputID = UUID().uuidString
                let event = Self.event(source: fixture.source, outputID: outputID)
                _ = try await store.accept(event, sourceID: fixture.source.id, targets: fixture.targets)
                if change == "revoked-source" {
                    _ = try await app.grove[SourceBindingService.self].revoke(id: fixture.source.id)
                }
                let candidate = change == "bytes" ? Self.event(source: fixture.source, outputID: outputID, rawSuffix: "altered") : event
                let targets = change == "targets" ? [fixture.targets[0]] : fixture.targets
                await #expect {
                    try await store.accept(candidate, sourceID: fixture.source.id, targets: targets)
                } throws: { ($0 as? ServerError)?.status.code == 409 }
                try await Self.expectRows(events: 1, nodes: 2, facts: 1, grants: 2, on: app.db)
            }
        }
    }

    @Test(arguments: ["missing-consent", "policy", "withdrawal", "collection-time"])
    func everyTargetRequiresCurrentConsentAndExactCollectionPolicy(failure: String) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await Self.prepare(on: app, consentCount: failure == "missing-consent" ? 1 : 2, secondPolicy: failure != "policy")
            try await AuthContext.$current.withValue(Self.participant) {
                if failure == "withdrawal" {
                    _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: fixture.enrollmentIDs[1])
                }
                let event = Self.event(source: fixture.source, effectiveAt: failure == "collection-time" ? .distantPast : Date())
                await #expect {
                    try await ClinicalEventStore(database: app.db).accept(event, sourceID: fixture.source.id, targets: fixture.targets)
                } throws: { ($0 as? ServerError)?.status.code == (failure == "missing-consent" ? 404 : 403) }
                try await Self.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
            }
        }
    }

    @Test
    func auditFailureRollsBackEveryEventNodeFactAndGrant() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await Self.prepare(on: app)
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("DROP TABLE audit_events").run()
            try await AuthContext.$current.withValue(Self.participant) {
                await #expect(throws: (any Error).self) {
                    try await ClinicalEventStore(database: app.db).accept(
                        Self.event(source: fixture.source), sourceID: fixture.source.id, targets: fixture.targets
                    )
                }
                try await Self.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
            }
        }
    }

    @Test
    func eventCannotImpersonateAnotherRegisteredSource() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await Self.prepare(on: app)
            try await AuthContext.$current.withValue(Self.participant) {
                let otherSource = try await app.grove[SourceBindingService.self].register(registrationID: UUID())
                await #expect {
                    try await ClinicalEventStore(database: app.db).accept(
                        Self.event(source: fixture.source), sourceID: otherSource.id, targets: fixture.targets
                    )
                } throws: { ($0 as? ServerError)?.status.code == 403 }
                try await Self.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
            }
        }
    }

    @Test
    func eventHistoryIsAppendOnlyAndGrantConsentCannotCrossEnrollments() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await Self.prepare(on: app)
            try await AuthContext.$current.withValue(Self.participant) {
                _ = try await ClinicalEventStore(database: app.db).accept(
                    Self.event(source: fixture.source), sourceID: fixture.source.id, targets: fixture.targets
                )
            }
            let sql = try #require(app.db as? any SQLDatabase)
            for table in ["clinical_events", "clinical_event_nodes", "clinical_point_facts", "study_data_grants"] {
                let column = table == "clinical_point_facts" ? "node_id" : "id"
                await #expect {
                    try await sql.raw("UPDATE \(ident: table) SET \(ident: column) = \(ident: column)").run()
                } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            }
            // Different consent produces a new uniqueness tuple, so only the exact-identity FK can reject this insert.
            await #expect {
                try await sql.raw("""
                    INSERT INTO study_data_grants (id, node_id, source_id, participant_id, study_id, enrollment_id,
                        consent_id, publication_id, revision, accepted_at)
                    SELECT \(bind: UUID()), g.node_id, g.source_id, g.participant_id, g.study_id, g.enrollment_id,
                        other.consent_id, g.publication_id, g.revision, g.accepted_at
                    FROM study_data_grants g JOIN study_data_grants other ON other.node_id = g.node_id AND other.enrollment_id <> g.enrollment_id
                    WHERE g.enrollment_id = \(bind: fixture.enrollmentIDs[0])
                    """)
                    .run()
            } throws: { ($0 as? any DatabaseError)?.isConstraintFailure == true }
            try await Self.expectRows(events: 1, nodes: 2, facts: 1, grants: 2, on: app.db)
        }
    }

    @Test
    func grantCannotConnectAnotherParticipantsConsentedEnrollment() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await Self.prepare(on: app)
            try await AuthContext.$current.withValue(Self.participant) {
                _ = try await ClinicalEventStore(database: app.db).accept(
                    Self.event(source: fixture.source), sourceID: fixture.source.id, targets: fixture.targets
                )
            }
            let other = try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: "other-participant")
            let enrollmentID = try await AuthContext.$current.withValue(Self.otherParticipant) {
                let enrollment = try await app.grove[ParticipantEnrollmentService.self].enroll(studyId: fixture.studyIDs[0], invitationCode: nil)
                let id = try enrollment.requireID()
                _ = try await Self.acceptConsent(enrollmentID: id, on: app)
                return id
            }
            let sql = try #require(app.db as? any SQLDatabase)
            // All publication/consent/enrollment triples are valid. Neither choice of owner may bridge the two participants.
            for participantID in [fixture.source.participantID, try other.requireID()] {
                await #expect {
                    try await sql.raw("""
                        INSERT INTO study_data_grants (id, node_id, source_id, participant_id, study_id, enrollment_id,
                            consent_id, publication_id, revision, accepted_at)
                        SELECT \(bind: UUID()), g.node_id, g.source_id, \(bind: participantID), g.study_id, c.enrollment_id,
                            c.id, g.publication_id, c.revision, g.accepted_at
                        FROM study_data_grants g JOIN enrollment_consents c ON c.enrollment_id = \(bind: enrollmentID)
                        WHERE g.enrollment_id = \(bind: fixture.enrollmentIDs[0])
                        """)
                        .run()
                } throws: { error in
                    (error as? PSQLError)?.serverInfo?[.sqlState] == "23503"
                        || (error as? SQLiteError)?.reason == .constraintForeignKeyFailed
                }
            }
            try await Self.expectRows(events: 1, nodes: 2, facts: 1, grants: 2, on: app.db)
        }
    }
}


extension ClinicalEventStoreTests {
    @Test
    func persistedEventBoundsRejectInvalidDigestCountAndText() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await Self.prepare(on: app)
            let sql = try #require(app.db as? any SQLDatabase)
            let digest = String(repeating: "a", count: 64)
            let cases: [InvalidEventRow] = [
                .init(identifier: "", digest: digest, count: 1, bytes: Data([1])),
                .init(identifier: String(repeating: "x", count: 513), digest: digest, count: 1, bytes: Data([1])),
                .init(identifier: "event", digest: String(repeating: "A", count: 64), count: 1, bytes: Data([1])),
                .init(identifier: "event", digest: String(repeating: "g", count: 64), count: 1, bytes: Data([1])),
                .init(identifier: "event", digest: digest, count: 0, bytes: Data([1])),
                .init(identifier: "event", digest: digest, count: 513, bytes: Data([1])),
                .init(identifier: "event", digest: digest, count: 1, bytes: Data()),
                .init(identifier: "event", digest: digest, count: 1, bytes: Data(repeating: 1, count: 4 * 1024 * 1024 + 1))
            ]
            for invalid in cases {
                await #expect {
                    try await sql.raw("""
                        INSERT INTO clinical_events (id, source_id, identifier_system, identifier_value, raw_bytes, raw_sha256,
                            validator_identity, target_intent, received_at, node_count)
                        VALUES (\(bind: UUID()), \(bind: fixture.source.id), 'urn:test:event', \(bind: invalid.identifier),
                            \(bind: invalid.bytes), \(bind: invalid.digest), 'synthetic', '[]', CURRENT_TIMESTAMP, \(bind: invalid.count))
                        """)
                        .run()
                } throws: { Self.isCheckFailure($0) }
            }
            try await Self.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
        }
    }

    @Test
    func persistedNodeAndPointBoundsAreCheckedBeforeInsertion() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await Self.prepare(on: app)
            try await AuthContext.$current.withValue(Self.participant) {
                _ = try await ClinicalEventStore(database: app.db).accept(
                    Self.event(source: fixture.source), sourceID: fixture.source.id, targets: fixture.targets
                )
            }
            let sql = try #require(app.db as? any SQLDatabase)
            for (fullURL, ordinal) in [("", 2), (String(repeating: "x", count: 513), 2), ("urn:new:point", 512)] {
                await #expect {
                    try await sql.raw("""
                        INSERT INTO clinical_event_nodes (id, event_id, source_id, full_url, ordinal, resource_type)
                        SELECT \(bind: UUID()), id, source_id, \(bind: fullURL), \(bind: ordinal), 'Observation' FROM clinical_events
                        """)
                        .run()
                } throws: { Self.isCheckFailure($0) }
            }
            let cases = [("", "72"), ("profile", ""), ("profile", String(repeating: "1", count: 4097))]
            for (profile, quantity) in cases {
                await #expect {
                    try await sql.raw("""
                        INSERT INTO clinical_point_facts (node_id, source_id, event_id, record_id, output_binding_id, profile, effective_at,
                            quantity_value, quantity_system, quantity_code, code_system, code)
                        SELECT n.id, n.source_id, f.event_id, f.record_id, f.output_binding_id, \(bind: profile), CURRENT_TIMESTAMP,
                            \(bind: quantity), 'http://unitsofmeasure.org', '/min', 'http://loinc.org', '8867-4'
                        FROM clinical_event_nodes n JOIN clinical_point_facts f ON f.event_id = n.event_id WHERE n.ordinal = 0
                        """)
                        .run()
                } throws: { Self.isCheckFailure($0) }
            }
            try await Self.expectRows(events: 1, nodes: 2, facts: 1, grants: 2, on: app.db)
        }
    }
}


extension ClinicalEventStoreTests {
    private static var otherParticipant: AuthContext {
        .init(
            issuer: TestApp.issuer,
            subject: "other-participant",
            email: "other@example.test",
            roles: [TestApp.participantRole],
            groups: [],
            researcherRole: TestApp.researcherRole,
            participantRole: TestApp.participantRole
        )
    }

    static var participant: AuthContext {
        .init(
            issuer: TestApp.issuer,
            subject: "test-participant",
            email: "test@example.test",
            roles: [TestApp.participantRole],
            groups: [],
            researcherRole: TestApp.researcherRole,
            participantRole: TestApp.participantRole
        )
    }

    static var researcher: AuthContext {
        .init(
            issuer: TestApp.issuer,
            subject: "test-researcher",
            email: "test@example.test",
            roles: [TestApp.researcherRole],
            groups: ["/Test Group/admin"],
            researcherRole: TestApp.researcherRole,
            participantRole: TestApp.participantRole
        )
    }

    private static func isCheckFailure(_ error: any Error) -> Bool {
        (error as? PSQLError)?.serverInfo?[.sqlState] == "23514"
            || (error as? SQLiteError)?.reason == .constraintCheckFailed
    }

    static func prepare(on app: Application, consentCount: Int = 2, secondPolicy: Bool = true) async throws -> Fixture {
        try await ParticipantFixtures.createParticipant(on: app.db)
        let group = try await GroupFixtures.createGroup(on: app.db)
        let studyIDs = try await AuthContext.$current.withValue(researcher) {
            var ids: [UUID] = []
            for index in 0..<2 {
                let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
                study.consent[.enUS] = ConsentContent(title: "Consent", content: "<toggle id=\"agree\" expected-value=\"true\">I agree.</toggle>")
                if index == 0 || secondPolicy {
                    study.collectionRequirements = [.init(profile: CollectionRequirement.supportedProfile, sourceKind: .participantApp)]
                }
                try await study.save(on: app.db)
                try await PublishedStudyFixtures.createNextClinicalRevision(on: app.db, studyId: study.requireId())
                ids.append(try study.requireId())
            }
            return ids
        }
        return try await AuthContext.$current.withValue(participant) {
            var enrollmentIDs: [UUID] = []
            var consentIDs: [UUID] = []
            for (index, studyID) in studyIDs.enumerated() {
                let enrollment = try await app.grove[ParticipantEnrollmentService.self].enroll(studyId: studyID, invitationCode: nil)
                let id = try enrollment.requireID()
                if index < consentCount {
                    consentIDs.append(try await acceptConsent(enrollmentID: id, on: app).requireID())
                } else {
                    consentIDs.append(UUID()) // Explicitly unknown consent for the negative fixture.
                }
                enrollmentIDs.append(id)
            }
            let source = try await app.grove[SourceBindingService.self].register(registrationID: UUID())
            return Fixture(source: source, studyIDs: studyIDs, enrollmentIDs: enrollmentIDs, consentIDs: consentIDs)
        }
    }

    static func acceptConsent(enrollmentID: UUID, on app: Application, revision: Int? = nil) async throws -> EnrollmentConsent {
        let service = app.grove[ConsentService.self]
        let (presentation, version) = try await service.getPresentation(enrollmentId: enrollmentID, locale: "en-US", revision: revision)
        return try await service.createConsent(
            enrollmentId: enrollmentID,
            commandID: UUID(),
            expectedEnrollmentVersion: version,
            reviewedRevision: presentation.revision,
            presentationProof: .init(presentationID: presentation.presentationID, locale: presentation.locale, digest: presentation.digest),
            userResponses: .init(toggles: ["agree": true]),
            pdfData: Data("%PDF-1.4 Synthetic consent evidence".utf8)
        )
    }

    static func event(
        source: SourceBinding, sequence: Int = 1, outputID: String = UUID().uuidString, rawSuffix: String = "", effectiveAt: Date = Date()
    ) -> ValidatedExchangeEvent {
        .init(
            rawBytes: Data("Synthetic prevalidated storage projection \(sequence) \(rawSuffix)".utf8),
            validatorIdentity: "storage-unit-fixture-not-official-validation",
            eventIdentifierSystem: source.eventIdentifierSystem,
            eventIdentifierValue: "e0:\(source.id.uuidString.lowercased()):\(sequence)",
            producerInstance: source.id,
            deploymentIdentifiers: .init(systems: [.event: [source.eventIdentifierSystem]]),
            participants: [.init(system: source.participantIdentifierSystem, value: source.participantIdentifierValue)],
            nodes: [
                .init(ordinal: 0, fullURL: "urn:uuid:patient", resourceType: "Patient"),
                .init(ordinal: 1, fullURL: "urn:uuid:point", resourceType: "Observation")
            ],
            outputs: [
                .init(
                    fullURL: "urn:uuid:point",
                    profile: CollectionRequirement.supportedProfile,
                    effectiveAt: effectiveAt,
                    sourceRecordIdentifier: .init(system: "https://example.test/source-record", value: "source-" + outputID),
                    sourceOutputIdentifier: .init(system: "https://example.test/output", value: outputID),
                    writerIdentifier: nil,
                    writerVersion: nil,
                    quantityValue: "72.12345678901234567890123456789",
                    quantitySystem: "http://unitsofmeasure.org",
                    quantityCode: "/min",
                    codeSystem: "http://loinc.org",
                    code: "8867-4"
                )
            ]
        )
    }

    static func expectRows(events: Int, nodes: Int, facts: Int, grants: Int, on database: any Database) async throws {
        let sql = try #require(database as? any SQLDatabase)
        let counts = [("clinical_events", events), ("clinical_event_nodes", nodes), ("clinical_point_facts", facts), ("study_data_grants", grants)]
        for (table, count) in counts {
            let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM \(ident: table)").first())
            #expect(try row.decode(column: "count", as: Int.self) == count)
        }
    }
}
