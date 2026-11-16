//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import TroveAPIClient


struct NativeReconciliationClientTests {
    private typealias Fixture = HeartRatePlannerFixture
    private typealias Instruction = Components.Schemas.NativeCollectionReconciliationInstruction

    private actor Transport: ClientTransport {
        struct Call: Sendable {
            let operation: String
            let path: String
            let installation: String?
            let body: String
        }

        private let instructions: [Instruction]
        private let beforeReply: (@Sendable () async throws -> Void)?
        private var statuses: [HTTPResponse.Status]
        private(set) var calls: [Call] = []

        init(_ instructions: [Instruction], statuses: [HTTPResponse.Status] = [], beforeReply: (@Sendable () async throws -> Void)? = nil) {
            self.instructions = instructions
            self.statuses = statuses
            self.beforeReply = beforeReply
        }

        func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
            var bytes = Data()
            if let body {
                bytes = try await Data(collecting: body, upTo: 4_096)
            }
            let installation = try #require(HTTPField.Name("Trove-Source-Installation-ID"))
            calls.append(.init(
                operation: operationID,
                path: request.path ?? "",
                installation: request.headerFields[installation],
                body: String(decoding: bytes, as: UTF8.self)
            ))
            try await beforeReply?()
            let status = statuses.isEmpty ? nil : statuses.removeFirst()
            if let status, status != .ok {
                let problem = #"{"type":"about:blank","title":"Refused","status":\#(status.code)}"#
                return (.init(status: status, headerFields: [.contentType: "application/problem+json"]), HTTPBody(problem))
            }
            guard operationID == "requestParticipantCollectionReconciliations" else {
                return (.init(status: .noContent), nil)
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(TroveDateTranscoder().encode(date))
            }
            let response = Components.Schemas.NativeCollectionReconciliationResponse(instructions: instructions)
            return (.init(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(try encoder.encode(response)))
        }
    }

    private struct Setup {
        let state: ParticipantCollectionState
        let ended: Components.Schemas.ParticipantCollectionPlan
        let instruction: Instruction
        let id: UUID
    }

    /// One ongoing and one ended sleep enrollment; only the ended one may be asked about.
    private static func setup(_ journal: EventDeliveryJournal) async throws -> Setup {
        let now = try TroveDateTranscoder().decode(TroveDateTranscoder().encode(Date()))
        var ongoing = Fixture.plan(), ended = Fixture.plan()
        for index in [0, 1] {
            var plan = index == 0 ? ongoing : ended
            plan.asOf = now
            plan.windows[0].start = now.addingTimeInterval(-1_000)
            plan.windows[0].requirements[0].profile = CollectionObservationProfile.sleepStage.rawValue
            plan.windows[0].requirements[0].sourceTypeIdentifier = HealthKitQueryDefinition.Stream.sleepStage.sourceTypeIdentifier
            plan.windows[0].requirements[0].start = now.addingTimeInterval(-500)
            if index == 0 { ongoing = plan } else { ended = plan }
        }
        ended.endsAt = now.addingTimeInterval(-100)
        ended.windows[0].end = ended.endsAt
        ended.windows[0].requirements[0].end = ended.endsAt
        let state = try await Fixture.retain([ongoing, ended], in: journal)
        let window = ended.windows[0], requirement = window.requirements[0]
        let instruction = Instruction(
            id: UUID().uuidString.lowercased(),
            sourceId: DeliveryFixture.sourceID.uuidString.lowercased(),
            enrollmentId: ended.enrollmentId,
            studyId: ended.studyId,
            stateVersion: ended.stateVersion,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(900),
            consentId: window.consentId,
            publicationId: window.publicationId,
            revision: window.revision,
            profile: requirement.profile,
            sourceTypeIdentifier: try #require(requirement.sourceTypeIdentifier),
            start: requirement.start,
            end: try #require(requirement.end),
            includeWorkoutRoutes: false
        )
        return Setup(state: state, ended: ended, instruction: instruction, id: try #require(UUID(uuidString: instruction.id)))
    }

    private static func client(_ transport: Transport) throws -> Client {
        Client(serverURL: try #require(URL(string: "https://trove.test")), configuration: .trove, transport: transport)
    }

    @Test
    func onlyEndedEnrollmentsAreRequestedWithInstallationProofAndTheInstructionIsRetained() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let setup = try await Self.setup(journal)
            let transport = Transport([setup.instruction])
            let ids = try await ParticipantNativeReconciliation.request(
                journal: journal, sourceID: DeliveryFixture.sourceID, state: setup.state, client: Self.client(transport)
            ) {}
            #expect(ids == [setup.id])
            let calls = await transport.calls
            #expect(calls.map(\.path) == ["/participant/enrollments/\(setup.ended.enrollmentId)/collection-reconciliations"])
            #expect(calls.first?.installation == DeliveryFixture.epoch.uuidString.lowercased())
            #expect(calls.first?.body.contains(DeliveryFixture.sourceID.uuidString.lowercased()) == true)
            let selection = try await journal.nativeReconciliationSelection(id: setup.id, sourceID: DeliveryFixture.sourceID, state: setup.state)
            #expect(selection.checkpoint.cursor == nil && selection.authority.expiresAt == setup.instruction.expiresAt)
        }
    }

    @Test(arguments: [401, 503])
    func refusedOrUnavailableRequestRetainsNothing(status: Int) async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let setup = try await Self.setup(journal)
            let transport = Transport([setup.instruction], statuses: [.init(code: status)])
            let expected: ParticipantNativeReconciliation.RequestError = status == 401 ? .authenticationRequired : .unavailable
            await #expect(throws: expected) {
                try await ParticipantNativeReconciliation.request(
                    journal: journal, sourceID: DeliveryFixture.sourceID, state: setup.state, client: Self.client(transport)
                ) {}
            }
            await #expect(throws: ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized) {
                try await journal.nativeReconciliationSelection(id: setup.id, sourceID: DeliveryFixture.sourceID, state: setup.state)
            }
        }
    }

    @Test
    func withdrawalDuringTheRequestDiscardsTheLateResponse() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let setup = try await Self.setup(journal)
            let enrollmentID = try #require(UUID(uuidString: setup.ended.enrollmentId))
            let transport = Transport([setup.instruction]) { _ = try await journal.stopCollection(for: enrollmentID) }
            await #expect(throws: EventDeliveryJournal.JournalError.staleCollectionState) {
                try await ParticipantNativeReconciliation.request(
                    journal: journal, sourceID: DeliveryFixture.sourceID, state: setup.state, client: Self.client(transport)
                ) {}
            }
            let current = try await journal.collectionState()
            await #expect(throws: ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized) {
                try await journal.nativeReconciliationSelection(id: setup.id, sourceID: DeliveryFixture.sourceID, state: current)
            }
        }
    }

    @Test
    func lostCompletionIsRetriedWithoutAnotherQueryAndThenStops() async throws {
        try await DeliveryFixture.withJournal { journal, _ in
            let setup = try await Self.setup(journal)
            try await journal.retainNativeReconciliations([setup.instruction], for: DeliveryFixture.sourceID, replacing: setup.state)
            let selection = try await journal.nativeReconciliationSelection(id: setup.id, sourceID: DeliveryFixture.sourceID, state: setup.state)
            _ = try await journal.stage(from: selection.checkpoint, nextCursor: Data([1]), payloads: [], queryExhausted: true)
            let transport = Transport([], statuses: [.serviceUnavailable])
            let client = try Self.client(transport)
            await #expect(throws: ParticipantNativeReconciliation.RequestError.unavailable) {
                try await ParticipantNativeReconciliation.acknowledgeCompleted(
                    journal: journal, sourceID: DeliveryFixture.sourceID, client: client
                ) {}
            }
            #expect(try await journal.completedNativeReconciliations(for: DeliveryFixture.sourceID).map(\.id) == [setup.id])
            for _ in 0..<2 {
                try await ParticipantNativeReconciliation.acknowledgeCompleted(
                    journal: journal, sourceID: DeliveryFixture.sourceID, client: client
                ) {}
            }
            let calls = await transport.calls
            let path = "/participant/enrollments/\(setup.ended.enrollmentId.lowercased())/collection-reconciliations/\(setup.id.uuidString.lowercased())/complete"
            #expect(calls.map(\.path) == [path, path])
            #expect(calls.allSatisfy { $0.operation == "completeParticipantCollectionReconciliation" })
            #expect(try await journal.completedNativeReconciliations(for: DeliveryFixture.sourceID).isEmpty)
            #expect(try await journal.checkpoint(for: DeliveryFixture.sourceID, queryID: setup.id).cursor == Data([1]))
        }
    }
}
