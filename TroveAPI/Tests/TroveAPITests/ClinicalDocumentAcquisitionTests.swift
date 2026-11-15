// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

#if canImport(HealthKit) && !os(watchOS)

import Crypto
import Foundation
import GroveFHIRContract
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
import Testing
@testable import TroveAPIClient
@testable import TroveHealthKit


struct ClinicalDocumentAcquisitionTests {
    private typealias Fixture = HeartRatePlannerFixture

    @Test(arguments: ["1.0.2", "4.0.1"])
    func sourceDownloadWindowStagesTheWholeOriginalFileWithoutReinterpretingCareDates(version: String) async throws {
        let type = HKClinicalType(.labResultRecord)
        let stream = try HealthKitQueryDefinition.Stream(.clinicalDocument, sourceTypeIdentifier: type.identifier)
        let definition = try HealthKitQueryDefinition(stream: stream, kind: .live, start: Fixture.liveStart)
        try await DeliveryFixture.withJournal(query: definition.encoded()) { journal, _ in
            var plan = Fixture.plan(start: 100, end: 150)
            plan.windows[0].requirements[0].profile = stream.profile.rawValue
            plan.windows[0].requirements[0].sourceTypeIdentifier = type.identifier
            plan.windows[0].requirements[0].timeBasis = stream.timeBasis
            _ = try await Fixture.retain([plan], in: journal)
            let sample = try ClinicalDocumentFixture.sample(type: type, start: Fixture.date(90), end: Fixture.date(160), version: version)
            let acquisition = try HealthKitAcquisition(journal: journal, scope: DeliveryFixture.scope) {}
            let page = try await acquisition.collect(
                localID: DeliveryFixture.epoch,
                application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
                host: .init(operatingSystemVersion: "27.2")
            ) { _, _ in
                .init(added: [sample], deletedIDs: [], nextAnchor: QueryAnchor(HKQueryAnchor(fromValue: 1)), readDocument: { selected in
                    let record = try #require(selected as? HKClinicalRecord)
                    return try await HealthKitRecordingFile.clinicalRecord(record, relativePath: "documents/source.json", maximumByteCount: 4096)
                })
            }
            let eventID = try #require(page.eventIDs.first)
            let attempt = try #require(try await journal.prepareAttempt(eventID))
            let graph = try ExchangeGraph(validating: attempt.bytes, kind: .active)
            let documents = (graph.bundle.entry ?? []).compactMap { entry in
                if case .documentReference(let document)? = entry.resource { document } else { nil }
            }
            let document = try #require(documents.first)
            #expect(documents.count == 1 && document.context?.period == nil && document.content.first?.attachment.data == nil)
            let stored = try #require(attempt.recordings.first)
            let declaration = try #require(try await journal.recordingTransfer(for: stored.id)).commitment.declaration
            #expect(declaration.sourceTypeIdentifier == type.identifier && declaration.profile == stream.profile.rawValue)
            #expect(declaration.effectiveAt == sample.startDate && declaration.effectiveEnd == sample.endDate)
            #expect(declaration.content.sourceByteCount == ClinicalDocumentFixture.bytes.count)
            let sourceHash = SHA256.hash(data: ClinicalDocumentFixture.bytes).map { String(format: "%02x", $0) }.joined()
            #expect(declaration.content.sourceSHA256 == sourceHash)
            #expect(String(decoding: attempt.bytes, as: UTF8.self).contains(sample.uuid.uuidString.lowercased()))
            #expect(attempt.commitment.targetIntent.targets.map(\.consentID) == [try #require(UUID(uuidString: plan.windows[0].consentId))])
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID).cursor != nil)
        }
    }

    @Test(arguments: ["capacity", "cancelled"])
    func failedDocumentStagingPreservesItsCursorAndDoesNotKeepAPartialUpload(mode: String) async throws {
        let type = HKClinicalType(.labResultRecord)
        let stream = try HealthKitQueryDefinition.Stream(.clinicalDocument, sourceTypeIdentifier: type.identifier)
        let definition = try HealthKitQueryDefinition(stream: stream, kind: .live, start: Fixture.liveStart)
        try await DeliveryFixture.withJournal(query: definition.encoded()) { journal, _ in
            var plan = Fixture.plan(start: 100, end: 150)
            plan.windows[0].requirements[0].profile = stream.profile.rawValue
            plan.windows[0].requirements[0].sourceTypeIdentifier = type.identifier
            plan.windows[0].requirements[0].timeBasis = stream.timeBasis
            _ = try await Fixture.retain([plan], in: journal)
            let before = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let sample = try ClinicalDocumentFixture.sample(type: type, start: Fixture.date(110), end: Fixture.date(110))
            let acquisition = try HealthKitAcquisition(journal: journal, scope: DeliveryFixture.scope) {}
            await #expect(throws: (any Error).self) {
                try await acquisition.collect(
                    localID: DeliveryFixture.epoch,
                    application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
                    host: .init(operatingSystemVersion: "27.2")
                ) { _, _ in
                    .init(added: [sample], deletedIDs: [], nextAnchor: QueryAnchor(HKQueryAnchor(fromValue: 1)), readDocument: { selected in
                        if mode == "cancelled" { throw CancellationError() }
                        let record = try #require(selected as? HKClinicalRecord)
                        return try await HealthKitRecordingFile.clinicalRecord(record, relativePath: "documents/source.json", maximumByteCount: 1)
                    })
                }
            }
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID).cursor == before.cursor)
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
        }
    }

    @Test
    func reviewWithoutAnExactCDAScopeNeverRunsAnotherStream() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            _ = try await Fixture.retain([Fixture.plan(start: 100, end: 150)], in: journal)
            let state = try await journal.collectionState()
            #expect(state.snapshot?.permitsDocumentReview == false)
            let acquisition = try HealthKitAcquisition(journal: journal, scope: DeliveryFixture.scope) {}
            await #expect(throws: ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized) {
                try await acquisition.catchUp(
                    localID: DeliveryFixture.epoch,
                    application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
                    host: .init(operatingSystemVersion: "27.2"),
                    reviewDocuments: true
                ) { _, _ in
                    Issue.record("Document review must not fall back to ordinary collection")
                    throw HealthKitAcquisition.AcquisitionError.unsupportedDelta
                }
            }
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
        }
    }

    @Test
    func automaticPassDoesNotPromptForCDADocumentsOrAcknowledgeTheirCursors() async throws {
        let stream = try HealthKitQueryDefinition.Stream(.healthKitRecording, sourceTypeIdentifier: HKDocumentType(.CDA).identifier)
        let definition = try HealthKitQueryDefinition(stream: stream, kind: .live, start: Fixture.liveStart)
        try await DeliveryFixture.withJournal(query: definition.encoded()) { journal, _ in
            var plan = Fixture.plan(start: 100, end: 150)
            plan.windows[0].requirements[0].profile = stream.profile.rawValue
            plan.windows[0].requirements[0].sourceTypeIdentifier = stream.sourceTypeIdentifier
            plan.windows[0].requirements[0].timeBasis = stream.timeBasis
            _ = try await Fixture.retain([plan], in: journal)
            let before = try await journal.checkpoint(for: DeliveryFixture.sourceID)
            let acquisition = try HealthKitAcquisition(journal: journal, scope: DeliveryFixture.scope) {}
            let progress = try await acquisition.catchUp(
                localID: DeliveryFixture.epoch,
                application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
                host: .init(operatingSystemVersion: "27.2")
            ) { _, _ in
                Issue.record("Automatic collection must not run the foreground CDA document query")
                throw HealthKitAcquisition.AcquisitionError.unsupportedDelta
            }
            #expect(progress == .caughtUp)
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID).cursor == before.cursor)
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            await #expect(throws: HealthKitAcquisition.AcquisitionError.unsupportedDelta) {
                try await acquisition.catchUp(
                    localID: DeliveryFixture.epoch,
                    application: .init(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1"),
                    host: .init(operatingSystemVersion: "27.2"),
                    reviewDocuments: true
                ) { query, _ in
                    #expect(query.stream == stream)
                    throw HealthKitAcquisition.AcquisitionError.unsupportedDelta
                }
            }
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID).cursor == before.cursor)
        }
    }
}

#endif
