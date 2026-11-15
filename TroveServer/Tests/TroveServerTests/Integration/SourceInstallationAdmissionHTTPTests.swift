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


struct SourceInstallationAdmissionHTTPTests {
    enum InvalidProof: CaseIterable, Sendable {
        case missingID, missingCredential, malformedID, malformedCredential, wrongCredential, otherRepository, revoked

        var status: HTTPStatus {
            switch self {
            case .missingID, .missingCredential, .malformedID, .malformedCredential: .badRequest
            case .wrongCredential, .otherRepository: .forbidden
            case .revoked: .conflict
            }
        }
    }

    @Test(arguments: InvalidProof.allCases)
    func everyWriteRouteRequiresAnOwnedActiveInstallation(proof: InvalidProof) async throws {
        let validator = ClinicalEventBatchTests.validator { Issue.record("Invalid proof reached FHIR validation") }
        try await TestApp.withApp(token: .participant(subject: "test-participant"), validator: validator) { app, token in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let otherID = UUID()
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await app.grove[SourceBindingService.self].registerSource(registrationID: otherID, repositoryKind: .sensorKit)
                if proof == .revoked {
                    _ = try await app.grove[SourceInstallationService.self].revoke(registrationID: fixture.installationID)
                }
            }
            let event = try ClinicalEventBatchTests.submission(LocalPointEventFixture.bytes(source: fixture.source), fixture: fixture)
            let bundle = try ClinicalRecordBundleTests.bundle([event], sourceID: fixture.source.id)
            let bodies = [
                "events": try JSONEncoder().encode(event),
                "events/batch": try JSONEncoder().encode(Components.Schemas.EventBatchSubmission(events: [event])),
                "record-bundles": try JSONEncoder().encode(bundle),
                "events/\(UUID())/attributions": try JSONEncoder().encode(Components.Schemas.EventAttribution(
                    commandId: UUID().uuidString, targets: event.targets
                ))
            ]
            for (route, body) in bodies {
                try await app.test(.POST, "\(apiBasePath)/participant/sources/\(fixture.source.id)/\(route)", beforeRequest: {
                    $0.bearerAuth(token)
                    Self.setHeaders(&$0, proof: proof, installationID: fixture.installationID, otherID: otherID)
                    $0.headers.contentType = .json
                    $0.body = .init(data: body)
                }) { response in
                    #expect(response.status == proof.status, "Route: \(route)")
                    #expect(!response.body.string.contains(SourceBindingFixture.credentialBase64(fixture.installationID)))
                }
            }
            try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
        }
    }
}


extension SourceInstallationAdmissionHTTPTests {
    private static func setHeaders(
        _ request: inout TestingHTTPRequest, proof: InvalidProof, installationID: UUID, otherID: UUID
    ) {
        request.sourceInstallation(proof == .otherRepository ? otherID : installationID)
        switch proof {
        case .missingID: request.headers.remove(name: "Trove-Source-Installation-ID")
        case .missingCredential: request.headers.remove(name: "Trove-Source-Credential")
        case .malformedID: request.headers.replaceOrAdd(name: "Trove-Source-Installation-ID", value: "not-a-uuid")
        case .malformedCredential: request.headers.replaceOrAdd(name: "Trove-Source-Credential", value: "not-base64")
        case .wrongCredential:
            request.headers.replaceOrAdd(name: "Trove-Source-Credential", value: SourceBindingFixture.credentialBase64(otherID))
        case .otherRepository, .revoked: break
        }
    }
}
