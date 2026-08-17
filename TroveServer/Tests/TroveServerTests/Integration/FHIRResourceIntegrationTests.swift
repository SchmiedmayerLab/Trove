//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


@Suite(.serialized)
struct FHIRResourceIntegrationTests {
    private static let heartRateCode = "8867-4"
    private static let observationTime = "2026-08-17T12:00:00Z"

    @Test("Observation ingestion round-trips its resource and indexed projection")
    func observationRoundTrip() async throws {
        try await TestApp.withApp(token: .participant(subject: "fhir-round-trip-user")) { app, token in
            try await self.createProfile(on: app, token: token)
            try await self.createObservationFixtures(on: app, token: token)
            try await self.createOtherParticipantRecord(on: app)
            try await self.expectRoundTrip(on: app, token: token)
        }
    }

    @Test("Observation read rejects an inverted time window")
    func invertedTimeWindow() async throws {
        try await TestApp.withApp(token: .participant(subject: "fhir-invalid-window-user")) { app, token in
            try await self.createProfile(on: app, token: token)
            let query = "code=8867-4&start=2026-08-18T00%3A00%3A00Z&end=2026-08-17T00%3A00%3A00Z"
            try await app.test(.GET, "\(apiBasePath)/participant/fhir/resource?\(query)", beforeRequest: { request in
                request.bearerAuth(token)
            }) { response in
                #expect(response.status == .badRequest)
            }
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

    private func createObservationFixtures(on app: Application, token: String?) async throws {
        try await postObservation(
            code: Self.heartRateCode,
            time: Self.observationTime,
            value: 72.5,
            on: app,
            token: token
        )
        try await postObservation(code: "29463-7", time: Self.observationTime, value: 80, on: app, token: token)
        try await postObservation(
            code: Self.heartRateCode,
            time: "2026-08-15T12:00:00Z",
            value: 60,
            on: app,
            token: token
        )
    }

    private func createOtherParticipantRecord(on app: Application) async throws {
        let stored = try #require(
            // swiftlint:disable:next first_where
            await FHIRResourceRecord.query(on: app.db(.timescale))
                .filter(\.$code == Self.heartRateCode)
                .first()
        )
        let record = FHIRResourceRecord(
            participantID: UUID(),
            resourceType: stored.resourceType,
            time: try #require(stored.id).time,
            externalID: "other-participant-observation",
            resource: stored.resource.proxy,
            code: stored.code,
            codeSystem: stored.codeSystem,
            value: stored.value,
            valueCode: stored.valueCode,
            valueSystem: stored.valueSystem
        )
        try await record.save(on: app.db(.timescale))
    }

    private func expectRoundTrip(on app: Application, token: String?) async throws {
        let query = "code=8867-4&start=2026-08-17T11%3A59%3A00Z&end=2026-08-17T12%3A01%3A00Z"
        try await app.test(.GET, "\(apiBasePath)/participant/fhir/resource?\(query)", beforeRequest: { request in
            request.bearerAuth(token)
        }) { response in
            #expect(response.status == .ok)
            let resources = try response.content.decode([Components.Schemas.StoredFHIRResource].self)
            let resource = try #require(resources.first)
            #expect(resources.count == 1)
            #expect(resource.externalId == "heart-rate-observation")
            #expect(resource.resourceType == "Observation")
            #expect(resource.code == Self.heartRateCode)
            #expect(resource.codeSystem == "http://loinc.org")
            #expect(resource.value == 72.5)
            #expect(resource.valueCode == "/min")
            #expect(resource.valueSystem == "http://unitsofmeasure.org")
            try self.expectProjectionMatchesBody(resource)
        }
    }

    private func expectProjectionMatchesBody(_ resource: Components.Schemas.StoredFHIRResource) throws {
        let body = try jsonObject(resource.resource)
        #expect(body["resourceType"] as? String == resource.resourceType)
        let coding = try #require(
            ((body["code"] as? [String: Any])?["coding"] as? [[String: Any]])?.first
        )
        #expect(coding["code"] as? String == resource.code)
        #expect(coding["system"] as? String == resource.codeSystem)
        let quantity = try #require(body["valueQuantity"] as? [String: Any])
        #expect(quantity["value"] as? Double == resource.value)
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

    private func jsonObject(_ resource: Components.Schemas.FHIRResource) throws -> [String: Any] {
        let data = try JSONEncoder().encode(resource)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
