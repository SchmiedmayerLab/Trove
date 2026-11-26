//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import JWTKit
import Synchronization
import Testing
@testable import TroveServer
import VaporTesting


#if canImport(FoundationNetworking)
import FoundationNetworking


#endif


struct ValidationDisclosureHTTPTests {
    enum Route: CaseIterable {
        case invalidDraft, unavailableDraft, component

        var result: ValidationStatus {
            switch self {
            case .invalidDraft: .invalid
            case .unavailableDraft: .unavailable
            case .component: .valid
            }
        }
    }

    enum Change: CaseIterable {
        case revoke, edit
    }

    /// The worker performs the owner's HTTP mutation before answering the delegate's validation request.
    private final class Worker: Sendable {
        let request = Mutex<URLRequest?>(nil)
        let mutationStatus = Mutex<Int?>(nil)

        func validator(for route: Route) -> FHIRValidationClient {
            FHIRValidationClient(expectedIdentity: QuestionnaireWorkerReply.identity, sendForPurpose: { purpose, bytes in
                if let request = self.request.withLock({ $0 }) {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    self.mutationStatus.withLock { $0 = (response as? HTTPURLResponse)?.statusCode }
                }
                let status = route.result
                let diagnostics = status == .invalid ? [QuestionnaireWorkerReply.finding("synthetic-invalid")] : []
                return (
                    QuestionnaireWorkerReply.httpStatus(for: status),
                    try QuestionnaireWorkerReply.body(for: bytes, status: status, purpose: purpose, diagnostics: diagnostics)
                )
            })
        }
    }

    private static func request(_ url: URL, token: String, method: String = "POST") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func grant(at studyURL: URL, token: String) async throws -> UUID {
        var create = request(studyURL.appending(path: "delegations"), token: token)
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        create.httpBody = try JSONSerialization.data(withJSONObject: [
            "clientId": "trove-draft-editor",
            "preset": "editStudyDraft",
            "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(600))
        ])
        let (data, response) = try await URLSession.shared.data(for: create)
        try #require((response as? HTTPURLResponse)?.statusCode == 201)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require((object?["id"] as? String).flatMap { UUID(uuidString: $0) })
    }

    private static func expectReport(_ request: URLRequest, status: ValidationStatus) async throws {
        let (data, response) = try await URLSession.shared.data(for: request)
        try #require((response as? HTTPURLResponse)?.statusCode == 200)
        let report = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let receivedStatus = report?["status"] as? String
        try #require(receivedStatus == status.rawValue)
    }

    private static func exercise(
        _ app: Application, keys: JWTKeyCollection, worker: Worker, route: Route, change: Change
    ) async throws {
        let group = try await GroupFixtures.createGroup(on: app.db)
        let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
        let studyID = try study.requireId()
        let component = try await ComponentFixtures.createQuestionnaireComponent(on: app.db, studyId: studyID)
        try await StudyFixtures.approveAdministrationLanguages(studyID: studyID, on: app.db)
        let port = try #require(app.http.server.shared.localAddress?.port)
        let studyURL = try #require(URL(string: "http://127.0.0.1:\(port)/\(apiBasePath)/studies/\(studyID)"))
        let groups = ["/Test Group/admin"]
        let owner = try await TestApp.signToken(keys: keys, roles: [TestApp.researcherRole], groups: groups)
        let delegated = try await TestApp.signToken(keys: keys, roles: [TestApp.researcherRole], groups: groups, clientID: "trove-draft-editor")
        let grantID = try await grant(at: studyURL, token: owner)
        let tag = "\"\(study.draftRevision.uuidString)\""
        var mutation: URLRequest
        switch change {
        case .revoke:
            mutation = request(studyURL.appending(path: "delegations/\(grantID)/revoke"), token: owner)
        case .edit:
            mutation = request(studyURL, token: owner, method: "PATCH")
            mutation.setValue(tag, forHTTPHeaderField: "If-Match")
            mutation.setValue("application/json", forHTTPHeaderField: "Content-Type")
            mutation.httpBody = Data(#"{"icon":"changed"}"#.utf8)
        }
        let path = route == .component ? "components/\(try component.requireId())/validations" : "draft/validations"
        var validate = request(studyURL.appending(path: path), token: delegated)
        validate.setValue(grantID.uuidString, forHTTPHeaderField: "Trove-Delegation-ID")
        if route != .component { validate.setValue(tag, forHTTPHeaderField: "If-Match") }
        try await expectReport(validate, status: route.result)
        worker.request.withLock { $0 = mutation }
        let (data, response) = try await URLSession.shared.data(for: validate)
        let mutationStatus = worker.mutationStatus.withLock { $0 }
        try #require(mutationStatus == 200)
        let status = (response as? HTTPURLResponse)?.statusCode
        #expect(status == (change == .revoke ? 403 : 412))
        let problem = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let problemOnly = Set(problem.keys).isSubset(of: ["type", "title", "status", "detail", "instance"])
        #expect(problemOnly)
        #expect(try await StudyPublicationCandidate.query(on: app.db).count() == 0)
    }

    @Test(arguments: Route.allCases, Change.allCases)
    func rechecksBeforeDisclosingValidation(route: Route, change: Change) async throws {
        let worker = Worker()
        let app = try await TestApp.makeApplication()
        do {
            let authority = GrantorAuthorityProvider { actor in
                .init(issuer: actor.issuer, subject: actor.subject, enabled: true, roles: [TestApp.researcherRole], groups: ["/Test Group/admin"])
            }
            let keys = try await TestApp.configureTesting(app, validator: worker.validator(for: route), grantorAuthority: authority)
            try await app.asyncBoot()
            try await app.http.server.shared.start(address: .hostname("127.0.0.1", port: 0))
            try await Self.exercise(app, keys: keys, worker: worker, route: route, change: change)
        } catch {
            await app.http.server.shared.shutdown()
            try await TestDatabase.shutdown(app)
            throw error
        }
        await app.http.server.shared.shutdown()
        try await TestDatabase.shutdown(app)
    }
}
