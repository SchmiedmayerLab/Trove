//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import ModelsR4
import Testing
@testable import TroveServer
import VaporTesting


@Suite(.serialized)
struct FHIRResourceIntegrationTests {
    private static let heartRateCode = "8867-4"
    private static let observationTime = "2026-08-17T12:00:00Z"

    @Test("Authenticated observation ingestion persists the participant-scoped resource and projection")
    func observationIngestion() async throws {
        try await TestApp.withApp(token: .participant(subject: "fhir-round-trip-user")) { app, token in
            try await self.createProfile(on: app, token: token)
            try await postObservation(
                code: Self.heartRateCode,
                time: Self.observationTime,
                value: 72.5,
                on: app,
                token: token
            )

            let records = try await FHIRResourceRecord.query(on: app.db(.timescale)).all()
            let record = try #require(records.first)
            #expect(records.count == 1)

            let participant = try #require(
                // swiftlint:disable:next first_where
                try await Participant.query(on: app.db)
                    .filter(\.$identityProviderId == "fhir-round-trip-user")
                    .first()
            )
            #expect(record.id?.participantID == participant.id)
            #expect(record.id?.externalID == "heart-rate-observation")
            #expect(record.resourceType == "Observation")
            #expect(record.code == Self.heartRateCode)
            #expect(record.codeSystem == "http://loinc.org")
            #expect(record.value == 72.5)
            #expect(record.valueCode == "/min")
            #expect(record.valueSystem == "http://unitsofmeasure.org")
            try self.expectProjectionMatchesBody(record)
        }
    }

    @Test("Unsupported FHIR resources are rejected without persistence")
    func unsupportedResource() async throws {
        try await TestApp.withApp(token: .participant(subject: "fhir-unsupported-user")) { app, token in
            try await self.createProfile(on: app, token: token)
            try await app.test(.POST, "\(apiBasePath)/participant/fhir/resource", beforeRequest: { request in
                request.bearerAuth(token)
                try request.encodeJSONBody([
                    "resourceType": "Patient",
                    "id": "unsupported-patient"
                ])
            }) { response in
                #expect(response.status == .badRequest)
            }

            let records = try await FHIRResourceRecord.query(on: app.db(.timescale)).all()
            #expect(records.isEmpty)
        }
    }

    private func createProfile(on app: Application, token: String?) async throws {
        try await app.test(.POST, "\(apiBasePath)/participant/profile", beforeRequest: { request in
            request.bearerAuth(token)
            try request.encodeJSONBody(ParticipantFixtures.profileBody())
        }) { response in
            #expect(response.status == .created)
        }
    }

    private func expectProjectionMatchesBody(_ record: FHIRResourceRecord) throws {
        let body = try jsonObject(record.resource.proxy)
        #expect(body["resourceType"] as? String == record.resourceType)
        let coding = try #require(
            ((body["code"] as? [String: Any])?["coding"] as? [[String: Any]])?.first
        )
        #expect(coding["code"] as? String == record.code)
        #expect(coding["system"] as? String == record.codeSystem)
        let quantity = try #require(body["valueQuantity"] as? [String: Any])
        #expect(quantity["value"] as? Double == record.value)
    }

    private func postObservation(
        code: String,
        time: String,
        value: Double,
        on app: Application,
        token: String?
    ) async throws {
        try await app.test(.POST, "\(apiBasePath)/participant/fhir/resource", beforeRequest: { request in
            request.bearerAuth(token)
            try request.encodeJSONBody([
                "resourceType": "Observation",
                "id": code == Self.heartRateCode && time == Self.observationTime
                    ? "heart-rate-observation"
                    : UUID().uuidString,
                "status": "final",
                "code": ["coding": [["system": "http://loinc.org", "code": code]]],
                "effectiveDateTime": time,
                "valueQuantity": [
                    "value": value,
                    "unit": "beats/minute",
                    "system": "http://unitsofmeasure.org",
                    "code": "/min"
                ]
            ] as [String: Any])
        }) { response in
            #expect(response.status == .created)
        }
    }

    private func jsonObject(_ resource: ResourceProxy) throws -> [String: Any] {
        let data = try JSONEncoder().encode(resource)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
