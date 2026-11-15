//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveSensorKitFHIR
import SQLKit
import Testing
import TroveAPIClient
@testable import TroveServer
import VaporTesting


/// A query-created batch is granted to a study only when the study's window selects every row.
struct SensorRecordingRowWindowTests {
    fileprivate struct Submitted {
        let payload: SensorRecordingAttachmentFixture
        let receipt: Components.Schemas.RecordingTransferReceipt
        let result: Components.Schemas.EventBatchResult

        var eventID: UUID {
            get throws {
                guard case .EventReceipt(let receipt) = result else { throw ServerError.unexpectedError }
                return try #require(UUID(uuidString: receipt.eventId))
            }
        }
    }

    fileprivate struct Scenario {
        let app: Application
        let token: String?
        let source: ClinicalEventStoreTests.Fixture
        let firstRow: Date
    }

    @Test
    func studiesWithDifferentWindowsReceiveOnlyBatchesTheySelectCompletely() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant"), validator: ClinicalEventBatchTests.validator()) { app, token in
            let scenario = try await Scenario(app: app, token: token), source = scenario.source
            let refused = try await scenario.submit(rowCount: 4, studies: [0, 1])
            guard case .ProblemDetails(let problem) = refused.result else { throw ServerError.unexpectedError }
            #expect(problem.status == 403)
            #expect(try await Self.grants(on: app).isEmpty)
            try await ClinicalRecordingAttachmentTests.expectAttachment(refused.receipt, count: 0, state: .ready, on: app)

            let whole = try await scenario.submit(rowCount: 4, studies: [0])
            let wholeEvent = try whole.eventID
            #expect(try await Self.grants(on: app).map(\.studyID) == [source.studyIDs[0], source.studyIDs[0]])
            // The enclosing period overlaps the second study's window, but two rows lie outside it.
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                await #expect {
                    try await ClinicalAttributionStore(database: app.db).attribute(
                        eventID: wholeEvent,
                        sourceID: source.source.id,
                        commandID: UUID(),
                        targets: [.init(consentID: source.consentIDs[1], outputFullURLs: whole.payload.outputURLs)],
                        installation: source.installation
                    )
                } throws: { ($0 as? ServerError)?.status.code == 403 }
            }
            #expect(try await Self.grants(on: app).count == 2)

            let slice = try await scenario.submit(rowCount: 2, studies: [0, 1])
            _ = try slice.eventID
            let grants = try await Self.grants(on: app)
            #expect(grants.filter { $0.studyID == source.studyIDs[1] }.count == 2)
            let reader = try await StudyRecordingFixture.readerToken()
            let sliceGrant = try #require(grants.first { $0.studyID == source.studyIDs[1] && $0.fullURL == slice.payload.recordingURL })
            let wholeGrant = try #require(grants.first { $0.studyID == source.studyIDs[0] && $0.fullURL == whole.payload.recordingURL })
            #expect(try await Self.download(sliceGrant, on: app, token: reader) == slice.payload.original)
            #expect(try await Self.download(wholeGrant, on: app, token: reader) == whole.payload.original)
            #expect(slice.payload.original != whole.payload.original)
            #expect(try await StudyRecordingFixture.disclosureCount(on: app) == 2)
        }
    }

    @Test
    func grantWithoutRowProofDisclosesNoRecordingBytes() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant"), validator: ClinicalEventBatchTests.validator()) { app, token in
            let scenario = try await Scenario(app: app, token: token), source = scenario.source
            let whole = try await scenario.submit(rowCount: 4, studies: [0])
            let slice = try await scenario.submit(rowCount: 2, studies: [1])
            _ = try (whole.eventID, slice.eventID)
            let reader = try await StudyRecordingFixture.readerToken()
            let pages = "\(apiBasePath)/studies/\(source.studyIDs[1])/data"
            try await app.test(.GET, pages, beforeRequest: { $0.bearerAuth(reader) }) { #expect($0.status == .ok) }
            // A grant that bypassed admission still cannot release rows outside its consent window.
            let forged = try await Self.forgeGrant(study: source.studyIDs[1], fullURL: whole.payload.recordingURL, on: app)
            let path = StudyRecordingLocation.path(studyID: source.studyIDs[1], grantID: forged, versions: .current)
            try await app.test(.GET, path, beforeRequest: { $0.bearerAuth(reader) }) { #expect($0.status == .notFound) }
            #expect(try await StudyRecordingFixture.disclosureCount(on: app) == 0)
            let disclosedPages = try await Self.auditCount("study.data.disclosure", on: app)
            try await app.test(.GET, pages, beforeRequest: { $0.bearerAuth(reader) }) {
                #expect($0.status == .internalServerError && !$0.body.string.contains("bundleBase64"))
            }
            #expect(try await Self.auditCount("study.data.disclosure", on: app) == disclosedPages)
            let legitimate = try #require(try await Self.grants(on: app).first {
                $0.studyID == source.studyIDs[1] && $0.fullURL == slice.payload.recordingURL
            })
            #expect(try await Self.download(legitimate, on: app, token: reader) == slice.payload.original)
        }
    }

    @Test
    func forgedSummaryGrantFailsTheStudyPageWithoutDisclosure() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant"), validator: ClinicalEventBatchTests.validator()) { app, token in
            let scenario = try await Scenario(app: app, token: token), source = scenario.source
            let whole = try await scenario.submit(rowCount: 4, studies: [0])
            let slice = try await scenario.submit(rowCount: 2, studies: [1])
            _ = try (whole.eventID, slice.eventID)
            // The summary of the four-row batch describes rows outside the second study's window.
            _ = try await Self.forgeGrant(study: source.studyIDs[1], fullURL: whole.payload.summaryURL, on: app)
            let reader = try await StudyRecordingFixture.readerToken()
            try await app.test(.GET, "\(apiBasePath)/studies/\(source.studyIDs[1])/data", beforeRequest: { $0.bearerAuth(reader) }) {
                #expect($0.status == .internalServerError)
            }
            #expect(try await Self.auditCount("study.data.disclosure", on: app) == 0)
            // The first study's complete grants are unaffected.
            try await app.test(.GET, "\(apiBasePath)/studies/\(source.studyIDs[0])/data", beforeRequest: { $0.bearerAuth(reader) }) {
                #expect($0.status == .ok)
            }
        }
    }

    @Test(arguments: ["verification", "download"])
    func withdrawalWhileRecordingBytesAreReadGrantsAndDisclosesNothing(phase: String) async throws {
        let storage = RecordingDownloadStorage()
        try await TestApp.withApp(
            token: .participant(subject: "test-participant"), storageProvider: storage, validator: ClinicalEventBatchTests.validator()
        ) { app, token in
            let scenario = try await Scenario(app: app, token: token), source = scenario.source
            let withdraw: @Sendable () async throws -> Void = {
                try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                    _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: source.enrollmentIDs[1])
                }
            }
            if phase == "verification" {
                let refused = try await scenario.submit(rowCount: 2, studies: [0, 1]) { await storage.reset(afterRead: withdraw) }
                guard case .ProblemDetails(let problem) = refused.result else { throw ServerError.unexpectedError }
                #expect(problem.status == 403)
                #expect(await storage.reads == 1)
                #expect(try await Self.grants(on: app).isEmpty)
                try await ClinicalRecordingAttachmentTests.expectAttachment(refused.receipt, count: 0, state: .ready, on: app)
            } else {
                let slice = try await scenario.submit(rowCount: 2, studies: [0, 1])
                let grants = try await Self.grants(on: app)
                let withdrawn = try #require(grants.first { $0.studyID == source.studyIDs[1] && $0.fullURL == slice.payload.recordingURL })
                let retained = try #require(grants.first { $0.studyID == source.studyIDs[0] && $0.fullURL == slice.payload.recordingURL })
                let reader = try await StudyRecordingFixture.readerToken()
                await storage.reset(afterRead: withdraw)
                let path = StudyRecordingLocation.path(studyID: withdrawn.studyID, grantID: withdrawn.id, versions: .current)
                try await app.test(.GET, path, beforeRequest: { $0.bearerAuth(reader) }) {
                    #expect($0.status == .conflict && !$0.body.string.contains("timestamp,identifier"))
                }
                #expect(await storage.reads == 1)
                #expect(try await StudyRecordingFixture.disclosureCount(on: app) == 0)
                #expect(try await Self.download(retained, on: app, token: reader) == slice.payload.original)
            }
        }
    }
}


extension SensorRecordingRowWindowTests {
    private struct Grant {
        let id: UUID
        let studyID: UUID
        let fullURL: String
    }

    /// Copies the study's own authority onto a node it was never granted.
    private static func forgeGrant(study: UUID, fullURL: String, on app: Application) async throws -> UUID {
        let sql = try #require(app.db as? any SQLDatabase), forged = UUID()
        try await sql.raw("""
            INSERT INTO study_data_grants (id, node_id, source_id, participant_id, study_id, enrollment_id,
                consent_id, publication_id, revision, accepted_at)
            SELECT \(bind: forged), n.id, s.source_id, s.participant_id, s.study_id, s.enrollment_id,
                s.consent_id, s.publication_id, s.revision, s.accepted_at
            FROM study_data_grants s, clinical_event_nodes n
            WHERE s.study_id = \(bind: study) AND n.full_url = \(bind: fullURL)
            LIMIT 1
            """)
            .run()
        return forged
    }

    private static func auditCount(_ action: String, on app: Application) async throws -> Int {
        let sql = try #require(app.db as? any SQLDatabase)
        let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM audit_events WHERE action = \(bind: action)").first())
        return try row.decode(column: "count", as: Int.self)
    }

    private static func grants(on app: Application) async throws -> [Grant] {
        let sql = try #require(app.db as? any SQLDatabase)
        return try await sql.raw("""
            SELECT g.id, g.study_id, n.full_url FROM study_data_grants g JOIN clinical_event_nodes n ON n.id = g.node_id
            ORDER BY g.accepted_at, n.ordinal
            """)
            .all()
            .map {
                try Grant(
                    id: $0.decode(column: "id", as: UUID.self),
                    studyID: $0.decode(column: "study_id", as: UUID.self),
                    fullURL: $0.decode(column: "full_url", as: String.self)
                )
            }
    }

    private static func download(_ grant: Grant, on app: Application, token: String) async throws -> Data {
        let response = try await RecordingTransferHTTPTests.client(app, token: token).getStudyRecording(.init(path: .init(
            studyId: grant.studyID.uuidString, grantId: grant.id.uuidString
        ))).ok
        return try await Data(collecting: response.body.binary, upTo: 4096)
    }
}


extension SensorRecordingRowWindowTests.Scenario {
    /// The second study's window ends before the third row of a four-row batch.
    fileprivate init(app: Application, token: String?) async throws {
        let firstRow = SensorRecordingAttachmentFixture.firstRow
        let definition = try SensorRecordingAttachmentFixture.source
        let start = Components.Schemas.ExportSessionStartDate.absolute(.init(_type: .absolute, date: Date().addingTimeInterval(-3600)))
        let requirements = try [nil, firstRow.addingTimeInterval(2)].map { end in
            try [#require(definition.observation?.primaryProfile), SensorKitContract.recordingDocumentProfile].map { profile in
                CollectionRequirement(
                    profile: profile,
                    sourceKind: .participantApp,
                    measurementWindow: .init(calendar: .gregorian, timeZone: "UTC", start: start, end: end),
                    sourceTypeIdentifier: definition.sourceToken
                )
            }
        }
        self.init(
            app: app,
            token: token,
            source: try await ClinicalEventStoreTests.prepare(on: app, requirements: requirements, repositoryKind: .sensorKit),
            firstRow: firstRow
        )
    }

    fileprivate func submit(
        rowCount: Int, studies: [Int], afterUpload: () async throws -> Void = {}
    ) async throws -> SensorRecordingRowWindowTests.Submitted {
        var payload = try await SensorRecordingAttachmentFixture.make(
            source: source.source, consentID: source.consentIDs[studies[0]], compressed: false, firstRow: firstRow, rowCount: rowCount
        )
        payload.recording.declaration.targets = studies.map {
            .init(consentId: source.consentIDs[$0].uuidString, outputFullUrls: [payload.recordingURL])
        }
        let receipt = try await ClinicalRecordingAttachmentTests.upload(payload.recording, source: source, on: app, token: token)
        try await afterUpload()
        var submission = payload.recording
        submission.declaration.targets = studies.map { .init(consentId: source.consentIDs[$0].uuidString, outputFullUrls: payload.outputURLs) }
        let results = try await ClinicalRecordingAttachmentTests.submit(
            submission.submission(sourceID: source.source.id, receipt: receipt), source: source, on: app, token: token
        )
        return .init(payload: payload, receipt: receipt, result: try #require(results.first))
    }
}
