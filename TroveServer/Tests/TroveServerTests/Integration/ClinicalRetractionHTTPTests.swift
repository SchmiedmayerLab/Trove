//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


struct ClinicalRetractionHTTPTests {
    @Test(.enabled(if: Environment.get("TROVE_TEST_VALIDATOR_ASSETS") != nil, "Requires the pinned full IG validator"), arguments: [true, false])
    func fullValidationRetractionInBothArrivalOrdersAndReceiptRecovery(retractionFirst: Bool) async throws {
        try #require(Environment.get("FHIR_VALIDATOR_URL") != nil && Environment.get("FHIR_VALIDATOR_IDENTITY") != nil)
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let active = try ImmutablePointEventFixture.bytes(source: fixture.source)
            let retraction = try RetractionEventFixture.bytes(activeBytes: active)
            let projected = try FHIRPointProjection.project(validatedBytes: active, validatorIdentity: "test-framing-only")
            let targets = fixture.targets(for: projected).map {
                Components.Schemas.EventTarget(consentId: $0.consentID.uuidString, outputFullUrls: $0.outputFullURLs)
            }
            let bodies = [
                Components.Schemas.EventSubmission(eventBase64: active.base64EncodedString(), targets: targets),
                .init(eventBase64: retraction.base64EncodedString(), targets: [])
            ]
            var receipt: Components.Schemas.EventReceipt?
            for index in retractionFirst ? [1, 0] : [0, 1] {
                let body = bodies[index]
                try await app.test(.POST, "\(apiBasePath)/participant/sources/\(fixture.source.id)/events", beforeRequest: {
                    $0.bearerAuth(token)
                    try $0.encodeJSONBody(body)
                }) { response in
                    try #require(response.status == .ok, "Synthetic retraction flow returned: \(response.body.string)")
                    if index == 1 { receipt = try response.content.decode(Components.Schemas.EventReceipt.self) }
                }
            }
            let retained = try #require(receipt)
            #expect(retained.targetIntentSHA256 == "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945")
            #expect(retained.nodeCount == 1)
            let store = ClinicalEventStore(database: app.db)
            for study in fixture.studyIDs { #expect(try await store.effectiveGrantCount(studyID: study) == 0) }
            try await Self.recoverAfterRevocation(retained, sourceID: fixture.source.id, on: app, token: token)
        }
    }
}


extension ClinicalRetractionHTTPTests {
    private static func recoverAfterRevocation(
        _ retained: Components.Schemas.EventReceipt, sourceID: UUID, on app: Application, token: String?
    ) async throws {
        try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            _ = try await SourceBindingService(database: app.db).revoke(id: sourceID)
        }
        let lookup = Components.Schemas.EventReceiptLookup(
            producerEventIdentifier: .init(system: retained.producerEventIdentifier.system, value: retained.producerEventIdentifier.value),
            payloadSHA256: retained.payloadSHA256,
            targets: []
        )
        try await app.test(.POST, "\(apiBasePath)/participant/sources/\(sourceID)/event-receipts/lookup", beforeRequest: {
            $0.bearerAuth(token)
            try $0.encodeJSONBody(lookup)
        }) { response in
            try #require(response.status == .ok)
            #expect(try response.content.decode(Components.Schemas.EventReceipt.self) == retained)
        }
    }
}
