//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import GroveFHIRContract
import Testing
@testable import TroveAPIClient


#if canImport(Darwin)
import Darwin


#endif


/// Opt-in workload for the real journal/client/drainer. The HTTP peer is synthetic:
/// this does not establish full IG validation, real-server durability or HealthKit capture.
struct CollectionBacklogWorkloadTests {
    private struct Staged: Sendable {
        let id: UUID
        let byteCount: Int
        let digest: String
    }

    private struct Backlog: Sendable {
        var staged: [Staged] = []
        let failedOrdinal: Int
        let failedCheckpoint: EventDeliveryJournal.Checkpoint
        let checkpoints: [EventDeliveryJournal.Checkpoint]
        let liveQueryID: UUID
        let historyQueryID: UUID
        let databaseBytes: Int
    }

    private actor LiveCapture {
        private var value: Staged?

        func store(_ staged: Staged) throws {
            try #require(value == nil)
            value = staged
        }

        func result() throws -> Staged {
            try #require(value)
        }
    }

    private static let noteBytes = 768 * 1024
    private static let pendingBudget = 80 * 1024 * 1024
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let limits = EventDeliveryJournal.Limits(
        maximumBytes: pendingBudget,
        maximumEvents: 512,
        maximumDatabaseBytes: 256 * 1024 * 1024
    )

    private static func withReopened(
        _ url: URL, operation: (EventDeliveryJournal) async throws -> Void
    ) async throws {
        let journal = try EventDeliveryJournal(url: url, scope: DeliveryFixture.scope, mode: .openExisting, limits: limits)
        do {
            try await operation(journal)
        } catch {
            await journal.close()
            throw error
        }
        await journal.close()
    }

    private static func loseResponse(
        _ journal: EventDeliveryJournal, backlog: Backlog, transport: BacklogDeliveryTransport
    ) async throws {
        #expect(try await journal.pendingDeliveryIDs(limit: 128) == backlog.staged.map(\.id))
        #expect(try await journal.checkpoints(for: DeliveryFixture.sourceID) == backlog.checkpoints)
        let drainer = try drainer(journal, transport: transport, at: now)
        let results = try await drainer.drain(limit: 2)
        #expect(results.count == 2)
        #expect(try await journal.pendingDeliveryIDs(limit: 128) == backlog.staged.map(\.id))
        #expect(await transport.snapshot().submittedRecords == 2)
        #expect(await transport.snapshot().acceptedRecords == 2)
        #expect(try await journal.checkpoints(for: DeliveryFixture.sourceID) == backlog.checkpoints)
    }

    private static func recoverTwo(
        _ journal: EventDeliveryJournal, backlog: Backlog, transport: BacklogDeliveryTransport
    ) async throws -> Staged {
        let capture = LiveCapture()
        await transport.onSecondLookup {
            // The first real receipt transaction freed space; new live work is staged
            // while the real drainer is still awaiting the second receipt.
            let live = try await journal.checkpoint(for: DeliveryFixture.sourceID, queryID: backlog.liveQueryID)
            let staged = try await Self.stage(journal, checkpoint: live, ordinal: 10_000)
            try await capture.store(staged)
        }
        let drainer = try drainer(journal, transport: transport, at: now.addingTimeInterval(600))
        #expect(try await drainer.drain(limit: 2).map(\.status) == [.delivered, .delivered])
        let stats = await transport.snapshot()
        #expect(stats.lookupRequests == 2)
        #expect(stats.submittedRecords == 2)
        #expect(stats.duplicateSubmissions == 0)
        let live = try await capture.result()
        #expect(try await journal.status(for: live.id) == .pending)
        return live
    }

    private static func drainRest(
        _ journal: EventDeliveryJournal, backlog: Backlog, live: Staged, transport: BacklogDeliveryTransport
    ) async throws -> [Staged] {
        #expect(try await journal.checkpoint(
            for: DeliveryFixture.sourceID, queryID: backlog.failedCheckpoint.queryID
        ) == backlog.failedCheckpoint)
        let resumed = try await stage(journal, checkpoint: backlog.failedCheckpoint, ordinal: backlog.failedOrdinal)
        let expected = backlog.staged + [live, resumed]
        let drainer = try drainer(journal, transport: transport, at: now.addingTimeInterval(600))
        var passes = 0
        while !(try await journal.pendingDeliveryIDs(limit: 128)).isEmpty {
            let results = try await drainer.drain(limit: 4)
            try #require(!results.isEmpty)
            #expect(results.allSatisfy { $0.status == .delivered })
            passes += 1
            try #require(passes <= expected.count)
        }
        for entry in expected {
            let receipt = try #require(await journal.receipt(for: entry.id))
            #expect(receipt.payloadSHA256 == entry.digest)
            #expect(try await journal.status(for: entry.id) == .delivered)
        }
        let stats = await transport.snapshot()
        #expect(stats.submittedRecords == expected.count)
        #expect(stats.acceptedRecords == expected.count)
        #expect(stats.duplicateSubmissions == 0)
        #expect(stats.maximumBatchRecords <= 4)
        #expect(stats.maximumEnvelopeBytes <= EventSubmissionLimits.maximumEnvelopeBytes)
        #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID, queryID: backlog.historyQueryID).cursor != nil)
        #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID, queryID: backlog.liveQueryID).cursor == cursor(10_000))
        return expected
    }

    private static func fill(_ journal: EventDeliveryJournal, databaseURL: URL) async throws -> Backlog {
        let live = try await journal.checkpoint(for: DeliveryFixture.sourceID)
        let historyDefinition = try HealthKitQueryDefinition(
            profile: .heartRate, kind: .historical, start: now.addingTimeInterval(-180 * 86_400), end: now
        ).encoded()
        let history = try await journal.createQuery(for: live.sourceID, queryID: UUID(), definition: historyDefinition)
        var staged: [Staged] = []
        // Every eighth event is live: backlog growth must not monopolize or replace
        // the live checkpoint. The exact six-calendar-month policy is tested separately.
        for ordinal in 0..<128 {
            let queryID = ordinal.isMultiple(of: 8) ? live.queryID : history.queryID
            let checkpoint = try await journal.checkpoint(for: live.sourceID, queryID: queryID)
            let before = try await journal.checkpoints(for: live.sourceID)
            do {
                let next = try await stage(journal, checkpoint: checkpoint, ordinal: ordinal)
                staged.append(next)
                let other = try #require(before.first { $0.queryID != queryID })
                #expect(try await journal.checkpoint(for: live.sourceID, queryID: other.queryID) == other)
            } catch DeliveryJournalError.capacityExceeded {
                // Both histories and live acquisition must be transactionally refused at
                // capacity, retaining all already accepted payloads and both cursors.
                let checkpoints = try await journal.checkpoints(for: live.sourceID)
                #expect(checkpoints == before)
                #expect(try await journal.pendingDeliveryIDs(limit: 128) == staged.map(\.id))
                let liveAtCapacity = try await journal.checkpoint(for: live.sourceID, queryID: live.queryID)
                await #expect(throws: DeliveryJournalError.capacityExceeded) {
                    try await stage(journal, checkpoint: liveAtCapacity, ordinal: 9_999)
                }
                #expect(try await journal.checkpoints(for: live.sourceID) == checkpoints)
                #expect(try await journal.pendingDeliveryIDs(limit: 128) == staged.map(\.id))
                // Make the resumable failed coordinate historical even if a live attempt
                // happened to hit the capacity first.
                let failed = try await journal.checkpoint(for: live.sourceID, queryID: history.queryID)
                await #expect(throws: DeliveryJournalError.capacityExceeded) {
                    try await stage(journal, checkpoint: failed, ordinal: ordinal)
                }
                #expect(try await journal.checkpoints(for: live.sourceID) == checkpoints)
                return Backlog(
                    staged: staged,
                    failedOrdinal: ordinal,
                    failedCheckpoint: failed,
                    checkpoints: checkpoints,
                    liveQueryID: live.queryID,
                    historyQueryID: history.queryID,
                    databaseBytes: try journalFileBytes(databaseURL)
                )
            }
        }
        throw DeliveryJournalError.invalidConfiguration
    }

    private static func stage(
        _ journal: EventDeliveryJournal, checkpoint: EventDeliveryJournal.Checkpoint, ordinal: Int
    ) async throws -> Staged {
        // Each individual FHIR string is below the graph decoder's 1 MiB ceiling.
        // The synthetic note creates queue load; it is not a representative clinical workload.
        let record = try RecordFixture.make(
            sourceID: DeliveryFixture.sourceID,
            registrationID: DeliveryFixture.epoch,
            seed: "backlog-\(ordinal)",
            note: String(repeating: "x", count: noteBytes),
            sourceSeed: "backlog-\(ordinal)"
        )
        let digest = SHA256.hash(data: record.json).map { String(format: "%02x", $0) }.joined()
        let ids = try await journal.stage(
            from: checkpoint, nextCursor: cursor(ordinal), payloads: [
                .init(bytes: record.json, targets: [.init(consentID: DeliveryFixture.consentID, outputFullURLs: record.outputFullURLs)])
            ]
        )
        try #require(ids.count == 1)
        return Staged(id: try #require(ids.first), byteCount: record.json.count, digest: digest)
    }

    private static func cursor(_ ordinal: Int) -> Data {
        Data("backlog-cursor-\(ordinal)".utf8)
    }

    private static func drainer(
        _ journal: EventDeliveryJournal, transport: BacklogDeliveryTransport, at instant: Date
    ) throws -> EventDeliveryDrainer {
        let client = Client(serverURL: try #require(URL(string: DeliveryFixture.scope.backend)), configuration: .trove, transport: transport)
        return try EventDeliveryDrainer(journal: journal, scope: DeliveryFixture.scope, client: client, validateSession: {}, now: { instant })
    }

    private static func journalFileBytes(_ database: URL) throws -> Int {
        try [database, URL(fileURLWithPath: database.path + "-wal"), URL(fileURLWithPath: database.path + "-shm")].reduce(0) { total, file in
            guard FileManager.default.fileExists(atPath: file.path) else {
                return total
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            return total + (try #require(attributes[.size] as? Int))
        }
    }

    private static func report(
        backlog: Backlog, records: Int, timings: [String: Double], transport: BacklogDeliveryTransport.Snapshot
    ) throws {
        var values: [String: Any] = [
            "workload": "synthetic-journal-backlog-v1", "pendingBudgetBytes": pendingBudget,
            "pendingPayloadBytesAtCapacity": backlog.staged.reduce(0) { $0 + $1.byteCount }, "recordCount": records,
            "databaseAndWALBytesAtCapacity": backlog.databaseBytes, "submittedEnvelopeBytes": transport.submittedEnvelopeBytes,
            "maximumEnvelopeBytes": transport.maximumEnvelopeBytes, "maximumBundleBytes": transport.maximumBundleBytes,
            "maximumBatchRecords": transport.maximumBatchRecords, "lookupRequests": transport.lookupRequests,
            "duplicateSubmissions": transport.duplicateSubmissions,
            "peakResidentBytes": try peakResidentBytes(),
            "boundary": "synthetic HTTP peer; real generated client, journal and drainer; no full IG or physical acquisition proof"
        ]
        for (key, value) in timings { values[key] = value }
        let bytes = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        print("TROVE_BACKLOG_WORKLOAD " + String(decoding: bytes, as: UTF8.self))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TROVE_TEST_LARGE_BACKLOG"] == "1"))
    func pendingHistoryAbove64MiBCoexistsWithLiveCaptureAndRecoversReceiptsAfterRestart() async throws {
        let liveDefinition = try HealthKitQueryDefinition(profile: .heartRate, kind: .live, start: Self.now).encoded()
        let started = ProcessInfo.processInfo.systemUptime
        try await DeliveryFixture.withJournal(limits: Self.limits, query: liveDefinition) { journal, url in
            let backlog = try await Self.fill(journal, databaseURL: url)
            let pendingBytes = backlog.staged.reduce(0) { $0 + $1.byteCount }
            try #require(pendingBytes > 64 * 1024 * 1024)
            #expect(pendingBytes < Self.pendingBudget)
            let fillSeconds = ProcessInfo.processInfo.systemUptime - started
            await journal.close()
            let transport = BacklogDeliveryTransport()
            let recoveryStarted = ProcessInfo.processInfo.systemUptime
            try await Self.withReopened(url) { reopened in
                try await Self.loseResponse(reopened, backlog: backlog, transport: transport)
            }
            try await Self.withReopened(url) { reopened in
                let live = try await Self.recoverTwo(reopened, backlog: backlog, transport: transport)
                let recoverySeconds = ProcessInfo.processInfo.systemUptime - recoveryStarted
                let drainStarted = ProcessInfo.processInfo.systemUptime
                let expected = try await Self.drainRest(reopened, backlog: backlog, live: live, transport: transport)
                try Self.report(
                    backlog: backlog,
                    records: expected.count,
                    timings: [
                        "fillSeconds": fillSeconds,
                        "recoverySeconds": recoverySeconds,
                        "drainSeconds": ProcessInfo.processInfo.systemUptime - drainStarted,
                        "totalSeconds": ProcessInfo.processInfo.systemUptime - started
                    ],
                    transport: await transport.snapshot()
                )
            }
        }
    }
}


extension CollectionBacklogWorkloadTests {
    private static func peakResidentBytes() throws -> Int {
        #if canImport(Darwin)
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0)
        return Int(usage.ru_maxrss)
        #else
        let status = try String(contentsOfFile: "/proc/self/status", encoding: .utf8)
        let line = try #require(status.split(separator: "\n").first { $0.hasPrefix("VmHWM:") })
        let fields = line.split(whereSeparator: \.isWhitespace)
        try #require(fields.count == 3 && fields[2] == "kB")
        return try #require(Int(fields[1])) * 1024
        #endif
    }
}
