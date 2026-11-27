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


/// A provider route that becomes unavailable between validation and publication refuses publication with the
/// route diagnostic draft validation reports, and nothing is published.
struct PublicationRouteLossTests {
    private static var authority: GrantorAuthorityProvider {
        .init { actor in
            .init(issuer: actor.issuer, subject: actor.subject, enabled: true, roles: [TestApp.researcherRole], groups: ["/Test Group/admin"])
        }
    }

    private static func withApp(
        registration: ProviderRegistration, _ test: @escaping @Sendable (Application, String?) async throws -> Void
    ) async throws {
        try await TestApp.withApp(
            validator: QuestionnaireWorkerReply.validator(),
            grantorAuthority: authority,
            providerRuntime: { app, authorization, studies in
                ProviderRuntime(
                    registrations: .init(
                        database: app.db,
                        clients: [
                            WithingsMeasurementClient(transport: .init { _, _, _, _ in throw ProviderFailure.unavailable }, limits: .standard)
                        ],
                        registrationIDs: [registration.id],
                        authorization: authorization,
                        studies: studies
                    ),
                    connections: nil
                )
            },
            test
        )
    }

    private static func setApproval(_ approved: Bool, for registration: ProviderRegistration, on app: Application) async throws {
        try await ProviderRegistrationStore(database: app.db).configure(
            registration, approved: approved, audit: ClinicalEventStoreTests.researcher.auditContext
        )
    }

    private static func refusal(_ response: TestingHTTPResponse) throws -> Components.Schemas.ProblemDetails {
        #expect(response.status == .conflict)
        #expect(response.headers.contentType?.description.hasPrefix("application/problem+json") == true)
        return try JSONDecoder().decode(Components.Schemas.ProblemDetails.self, from: Data(buffer: response.body))
    }

    @Test
    func withdrawnRegistrationRefusesPublicationWithTheRouteDiagnostic() async throws {
        let registration = try ProviderFixture.registration()
        try await Self.withApp(registration: registration) { app, token in
            try await Self.setApproval(true, for: registration, on: app)
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let studyID = try study.requireId()
            let native = Components.Schemas.CollectionRequirement(
                profile: CollectionObservationProfile.heartRate.rawValue, sourceKind: .participantApp
            )
            // An optional route that is unavailable at validation stays out of the grant, so the provider requirement's
            // index in the draft differs from its index among the granted requirements.
            var unsupported = PublicationReadinessTests.unsupportedNativeRequirement
            unsupported.requirement = .optional
            var provider = Components.Schemas.CollectionRequirement(
                includeWorkoutRoutes: false,
                profile: CollectionObservationProfile.bodyWeight.rawValue,
                sourceTypeIdentifier: "getmeas:1",
                providerRegistrationId: registration.id.uuidString.lowercased(),
                sourceKind: .serverWorker
            )
            var revision = try await PublicationReadinessTests.patchRequirements(
                studyID, revision: study.draftRevision, [unsupported, native, provider], app: app, token: token
            )
            let report = try await PublicationReadinessTests.validate(studyID, app: app, token: token)
            #expect(report.status == .valid && report.routes.map(\.availability) == [.unavailable, .available, .available])
            let candidate = try #require(report.candidate)

            try await Self.setApproval(false, for: registration, on: app)
            let required = try Self.refusal(
                try await PublicationReadinessTests.publish(studyID, revision: revision, candidate: candidate.id, app: app, token: token)
            )
            #expect(required.status == 409)
            let diagnostic = try #require(required.diagnostics?.first)
            #expect(required.diagnostics?.count == 1)
            #expect(diagnostic.rule == "route-unavailable" && diagnostic.source == .trove && diagnostic.severity == .error)
            #expect(diagnostic.path == "collectionRequirements[2]")
            #expect(diagnostic.nextAction?.isEmpty == false)
            #expect(try await PublishedStudy.query(on: app.db).count() == 0)

            // An optional route lost after validation also refuses, because the candidate granted it.
            try await Self.setApproval(true, for: registration, on: app)
            provider.requirement = .optional
            revision = try await PublicationReadinessTests.patchRequirements(
                studyID, revision: revision, [unsupported, native, provider], app: app, token: token
            )
            let optionalCandidate = try #require(try await PublicationReadinessTests.validate(studyID, app: app, token: token).candidate)
            try await Self.setApproval(false, for: registration, on: app)
            let optional = try Self.refusal(
                try await PublicationReadinessTests.publish(
                    studyID, revision: revision, candidate: optionalCandidate.id, app: app, token: token
                )
            )
            #expect(optional.diagnostics?.map(\.path) == ["collectionRequirements[2]"])
            #expect(optional.diagnostics?.map(\.rule) == ["route-unavailable"])
            #expect(try await PublishedStudy.query(on: app.db).count() == 0)

            // Validating again records the lost optional route as unavailable, and the new candidate publishes.
            let revalidated = try await PublicationReadinessTests.validate(studyID, app: app, token: token)
            #expect(revalidated.advisories.map(\.rule) == ["route-optional-unavailable", "route-optional-unavailable"])
            let accepted = try await PublicationReadinessTests.publish(
                studyID, revision: revision, candidate: try #require(revalidated.candidate).id, app: app, token: token
            )
            #expect(accepted.status == .created)
            let publication = try accepted.content.decode(Components.Schemas.PublishedStudyResponse.self)
            #expect(publication.unavailableCollectionRequirements == [unsupported, provider])
        }
    }

    /// A draft with one required provider requirement, validated with an approved registration.
    private static func validatedProviderDraft(
        _ registration: ProviderRegistration, app: Application, token: String?
    ) async throws -> (studyID: UUID, revision: UUID, candidate: String) {
        try await Self.setApproval(true, for: registration, on: app)
        let group = try await GroupFixtures.createGroup(on: app.db)
        let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
        let studyID = try study.requireId()
        let provider = Components.Schemas.CollectionRequirement(
            includeWorkoutRoutes: false,
            profile: CollectionObservationProfile.bodyWeight.rawValue,
            sourceTypeIdentifier: "getmeas:1",
            providerRegistrationId: registration.id.uuidString.lowercased(),
            sourceKind: .serverWorker
        )
        let revision = try await PublicationReadinessTests.patchRequirements(
            studyID, revision: study.draftRevision, [provider], app: app, token: token
        )
        let report = try await PublicationReadinessTests.validate(studyID, app: app, token: token)
        #expect(report.status == .valid && report.routes.map(\.availability) == [.available])
        return (studyID, revision, try #require(report.candidate).id)
    }

    @Test
    func aRegistrationReconfiguredWithoutTheSourceRefusesPublicationWithTheRouteDiagnostic() async throws {
        let registration = try ProviderFixture.registration()
        try await Self.withApp(registration: registration) { app, token in
            let draft = try await Self.validatedProviderDraft(registration, app: app, token: token)
            let narrowed = try ProviderFixture.registration(id: registration.id, sourceTokens: ["getmeas:11"])
            try await ProviderRegistrationStore(database: app.db).configure(
                narrowed, approved: true, audit: ClinicalEventStoreTests.researcher.auditContext
            )
            let refusal = try Self.refusal(
                try await PublicationReadinessTests.publish(
                    draft.studyID, revision: draft.revision, candidate: draft.candidate, app: app, token: token
                )
            )
            #expect(refusal.title == "Collection Route Unavailable")
            #expect(refusal.diagnostics?.map(\.path) == ["collectionRequirements[0]"])
            #expect(refusal.diagnostics?.map(\.rule) == ["route-unavailable"])
            #expect(try await PublishedStudy.query(on: app.db).count() == 0)
        }
    }

    @Test
    func anUnreadableStoredRegistrationIsATypedServerError() async throws {
        let registration = try ProviderFixture.registration()
        try await Self.withApp(registration: registration) { app, token in
            let draft = try await Self.validatedProviderDraft(registration, app: app, token: token)
            try await ProviderSQL.sql(app.db)
                .raw("UPDATE provider_registrations SET configuration = '{}' WHERE id = \(bind: registration.id)")
                .run()
            let response = try await PublicationReadinessTests.publish(
                draft.studyID, revision: draft.revision, candidate: draft.candidate, app: app, token: token
            )
            #expect(response.status == .internalServerError)
            let problem = try JSONDecoder().decode(Components.Schemas.ProblemDetails.self, from: Data(buffer: response.body))
            #expect(problem.title == "Provider Registration Unreadable" && problem.diagnostics == nil)
            #expect(try await PublishedStudy.query(on: app.db).count() == 0)

            let validation = try await app.sendRequest(.POST, "\(apiBasePath)/studies/\(draft.studyID)/draft/validations") { request in
                request.bearerAuth(token)
                request.headers.replaceOrAdd(name: "If-Match", value: "\"\(draft.revision)\"")
            }
            #expect(validation.status == .internalServerError)
            #expect(try JSONDecoder().decode(Components.Schemas.ProblemDetails.self, from: Data(buffer: validation.body)).title
                == "Provider Registration Unreadable")
        }
    }
}
