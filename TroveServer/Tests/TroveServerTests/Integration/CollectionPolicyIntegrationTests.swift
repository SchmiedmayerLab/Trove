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
import ZIPFoundation


struct CollectionPolicyIntegrationTests {
    @Test
    func publishedPolicyMatchesArchiveAndDoesNotFollowDraftChanges() async throws {
        try await PublicationWorkflowFixtures.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let id = try study.requireId()
            let requirement = ["profile": CollectionRequirement.supportedProfile, "sourceKind": "participant-app"]
            try await Self.patch([requirement], study: study, app: app, token: token, expected: .ok)
            try await Self.publish(studyID: id, app: app, token: token)
            // swiftlint:disable:next first_where - Fluent SQL query, not a collection
            let first = try #require(try await PublishedStudy.query(on: app.db).filter(\.$revision == 1).first())
            let policy = first.collectionPolicy
            #expect(policy.studyID == id && policy.revision == 1)
            #expect(policy.requirements == [.init(profile: CollectionRequirement.supportedProfile, sourceKind: .participantApp)])
            #expect(!policy.receivesDeviceUnitIdentifiers, "Device unit identifiers are withheld by default")
            let bytes = try await app.grove[ObjectStorageService.self].download(key: first.bundleKey)
            let archive = try Archive(data: bytes, accessMode: .read)
            let entry = try #require(archive.first { $0.path.hasSuffix("/collection-policy.json") })
            var archivedPolicy = Data()
            _ = try archive.extract(entry) { archivedPolicy.append($0) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            #expect(archivedPolicy == (try encoder.encode(policy)))
            #expect(try JSONDecoder().decode(PublishedCollectionPolicy.self, from: archivedPolicy) == policy)
            let nextDraft = try #require(try await Study.find(id, on: app.db))
            try await Self.patch([], study: nextDraft, app: app, token: token, expected: .ok, receivesDeviceUnitIdentifiers: true)
            try await Self.publish(studyID: id, app: app, token: token)
            let retained = try #require(try await PublishedStudy.find(first.requireId(), on: app.db))
            // swiftlint:disable:next first_where - Fluent SQL query, not a collection
            let second = try #require(try await PublishedStudy.query(on: app.db).filter(\.$revision == 2).first())
            #expect(retained.collectionPolicy == policy)
            #expect(second.collectionPolicy.requirements.isEmpty)
            #expect(second.collectionPolicy.revision == 2)
            #expect(second.collectionPolicy.receivesDeviceUnitIdentifiers && !retained.collectionPolicy.receivesDeviceUnitIdentifiers)
        }
    }

    @Test(arguments: ["unsupported", "duplicate", "source"])
    func invalidRequirementPatchDoesNotChangeDraft(failure: String) async throws {
        try await TestApp.withApp { app, token in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: group.requireId())
            let id = try study.requireId()
            let requirement = [
                "profile": failure == "unsupported" ? "HKQuantityTypeIdentifierHeartRate" : CollectionRequirement.supportedProfile,
                "sourceKind": failure == "source" ? "healthkit" : "participant-app"
            ]
            try await Self.patch(
                failure == "duplicate" ? [requirement, requirement] : [requirement],
                study: study,
                app: app,
                token: token,
                expected: .badRequest
            )
            let retained = try #require(try await Study.find(id, on: app.db))
            #expect(retained.collectionRequirements.isEmpty)
        }
    }
}


extension CollectionPolicyIntegrationTests {
    private struct Patch: Encodable {
        let collectionRequirements: [[String: String]]
        /// Omitted unless set, so the first draft relies on the default.
        let receivesDeviceUnitIdentifiers: Bool? // swiftlint:disable:this discouraged_optional_boolean
    }

    private static func patch(
        _ requirements: [[String: String]],
        study: Study,
        app: Application,
        token: String?,
        expected: HTTPStatus,
        receivesDeviceUnitIdentifiers: Bool = false
    ) async throws {
        let studyID = try study.requireId()
        try await app.test(.PATCH, "\(apiBasePath)/studies/\(studyID)", beforeRequest: { request in
            request.bearerAuth(token)
            request.headers.replaceOrAdd(name: "If-Match", value: "\"\(study.draftRevision)\"")
            let setting: Bool? = receivesDeviceUnitIdentifiers ? true : nil // swiftlint:disable:this discouraged_optional_boolean
            try request.encodeJSONBody(Patch(collectionRequirements: requirements, receivesDeviceUnitIdentifiers: setting))
        }) { response in
            try #require(response.status == expected)
            if expected == .ok {
                let study = try response.content.decode(Components.Schemas.StudyResponse.self)
                #expect(study.collectionRequirements.count == requirements.count)
                #expect(study.receivesDeviceUnitIdentifiers == receivesDeviceUnitIdentifiers)
            }
        }
    }

    private static func publish(studyID: UUID, app: Application, token: String?) async throws {
        let response = try await PublicationWorkflowFixtures.publish(studyID, app: app, token: token)
        try #require(response.status == .created)
    }
}
