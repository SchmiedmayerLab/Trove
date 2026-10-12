//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import GroveHealthKit
import GroveHealthKitBulkExport
import GroveLocalization
import GroveStudyDefinition
import JWTKit
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting
import ZIPFoundation


@Suite(.serialized)
struct StudyBundleIntegrationTests {
    private struct ValidationReply: Encodable {
        let valid = true
        let sha256: String
        let contractRevision = FHIRValidationClient.contractRevision
        let validatorIdentity = "sha256:" + String(repeating: "a", count: 64)
        let purpose = "questionnaire"
    }

    private static let participantSubject = "bundle-test-participant"
    private static var validator: FHIRValidationClient {
        .init(expectedIdentity: "sha256:" + String(repeating: "a", count: 64), sendForPurpose: { purpose, bytes in
            #expect(purpose == .questionnaire)
            return (200, try JSONEncoder().encode(ValidationReply(sha256: ArtifactStore.digest(bytes))))
        })
    }

    // MARK: - Comprehensive Component Types Test

    @Test("Enrolled participant downloads a published bundle containing all component types")
    func downloadPublishedBundleWithAllComponentTypes() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: Self.validator) { app, researcherToken in
            let studyId = try await buildFullStudy(on: app.db)

            let publication = try await PublicationWorkflowFixtures.publish(studyId, app: app, token: researcherToken)
            try #require(publication.status == .created)

            let participantToken = try await Self.signParticipantToken(subject: Self.participantSubject)
            try await Self.createEnrollment(on: app.db, studyId: studyId, revision: 1)

            try await app.test(
                .GET,
                "\(apiBasePath)/participant/studies/\(studyId)/1/bundle",
                beforeRequest: { req in req.bearerAuth(participantToken) }
            ) { response in
                #expect(response.status == .ok)

                let contentDisposition = response.headers.first(name: .contentDisposition)
                #expect(contentDisposition?.contains("attachment") == true)
                #expect(contentDisposition?.contains(".studybundle.zip") == true)

                let bundle = try extractStudyBundle(from: Data(buffer: response.body))
                try verifyFullBundle(bundle, studyId: studyId)
            }
        }
    }

    // MARK: - Enrollment Required

    @Test("Returns 404 when participant tries to download a bundle without an enrollment")
    func downloadPublishedBundleRequiresEnrollment() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: Self.validator) { app, researcherToken in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let groupId = try group.requireId()
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: groupId, title: "Locked Study")
            let studyId = try study.requireId()

            let publication = try await PublicationWorkflowFixtures.publish(studyId, app: app, token: researcherToken)
            try #require(publication.status == .created)

            let participantToken = try await Self.signParticipantToken(subject: Self.participantSubject)
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.participantSubject)

            try await app.test(
                .GET,
                "\(apiBasePath)/participant/studies/\(studyId)/1/bundle",
                beforeRequest: { req in req.bearerAuth(participantToken) }
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test("Forbids researcher tokens from downloading the participant bundle")
    func downloadPublishedBundleForbiddenForResearcher() async throws {
        try await PublicationWorkflowFixtures.withApp(validator: Self.validator) { app, researcherToken in
            let group = try await GroupFixtures.createGroup(on: app.db)
            let groupId = try group.requireId()
            let study = try await StudyFixtures.createStudy(on: app.db, groupId: groupId, title: "Researcher Locked")
            let studyId = try study.requireId()

            let publication = try await PublicationWorkflowFixtures.publish(studyId, app: app, token: researcherToken)
            try #require(publication.status == .created)

            try await app.test(
                .GET,
                "\(apiBasePath)/participant/studies/\(studyId)/1/bundle",
                beforeRequest: { req in req.bearerAuth(researcherToken) }
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    @Test("Returns 404 when participant requests a non-existent study bundle")
    func downloadPublishedBundleNotFound() async throws {
        try await TestApp.withApp(token: .none) { app, _ in
            let participantToken = try await Self.signParticipantToken(subject: Self.participantSubject)
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: Self.participantSubject)
            let nonExistentId = UUID()

            try await app.test(
                .GET,
                "\(apiBasePath)/participant/studies/\(nonExistentId)/1/bundle",
                beforeRequest: { req in req.bearerAuth(participantToken) }
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }
}


extension StudyBundleIntegrationTests {
    // MARK: - Setup

    private static func signParticipantToken(subject: String) async throws -> String {
        let keys = JWTKeyCollection()
        await keys.add(hmac: HMACKey(from: TestApp.testSecret), digestAlgorithm: .sha256)
        return try await TestApp.signToken(
            keys: keys,
            subject: subject,
            roles: [TestApp.participantRole],
            groups: []
        )
    }

    private static func createEnrollment(on database: any Database, studyId: UUID, revision: Int) async throws {
        let participant = try await ParticipantFixtures.createParticipant(
            on: database,
            identityProviderId: participantSubject
        )
        let enrollment = Enrollment(
            participantId: try participant.requireId(),
            studyId: studyId,
            currentRevision: revision
        )
        try await enrollment.save(on: database)
    }

    /// Creates a full study with all component types, consent, and three schedules. Returns the study ID.
    private func buildFullStudy(on database: any Database) async throws -> UUID { // swiftlint:disable:this function_body_length
        let group = try await GroupFixtures.createGroup(on: database)
        let groupId = try group.requireId()
        let study = try await StudyFixtures.createStudy(on: database, groupId: groupId, title: "Bundle Test Study")
        let studyId = try study.requireId()

        // Consent
        study.consent = LocalizationsDictionary([
            .enUS: ConsentContent(title: "Informed Consent", content: "# Informed Consent\n\nPlease read carefully.")
        ])
        try await study.save(on: database)

        // Informational component
        let informationalComponent = try await ComponentFixtures.createInformationalComponent(
            on: database,
            studyId: studyId,
            name: "Welcome Article"
        )
        let informationalId = try informationalComponent.requireId()
        informationalComponent.data = .informational(LocalizationsDictionary([
            .enUS: InformationalContent(
                title: "Welcome",
                content: "# Welcome\nThis is the welcome article.",
                lede: "Introduction"
            )
        ]))
        try await informationalComponent.update(on: database)

        // Questionnaire component
        let questionnaireComponent = try await ComponentFixtures.createQuestionnaireComponent(
            on: database,
            studyId: studyId,
            name: "Daily Survey"
        )
        let questionnaireId = try questionnaireComponent.requireId()
        let questionnaireJSON = """
            {
              "resourceType": "Questionnaire",
              "id": "\(questionnaireId.uuidString)",
              "status": "active",
              "meta": {"profile": ["https://grovealliance.org/fhir/questionnaire/StructureDefinition/grove-questionnaire"]},
              "url": "https://example.org/fhir/Questionnaire/daily-survey",
              "version": "1.0.0",
              "subjectType": ["Patient"],
              "extension": [{
                "url": "http://hl7.org/fhir/StructureDefinition/artifact-versionAlgorithm",
                "valueCoding": {"system": "http://hl7.org/fhir/version-algorithm", "code": "semver"}
              }],
              "language": "en-US",
              "title": "Daily Survey",
              "item": [{"linkId": "mood", "text": "Rate your mood", "type": "integer"}]
            }
            """
        questionnaireComponent.data = .questionnaire(LocalizationsDictionary([
            .enUS: QuestionnaireContent(questionnaire: questionnaireJSON)
        ]))
        try await questionnaireComponent.update(on: database)

        // Health data component
        let healthDataComponent = try await ComponentFixtures.createHealthDataComponent(on: database, studyId: studyId)
        let healthDataId = try healthDataComponent.requireId()
        let historicalCollection = StudyDefinition.HealthDataCollectionComponent.HistoricalDataCollection.enabled(.last(numMonths: 6))
        healthDataComponent.data = .healthDataCollection(StudyDefinition.HealthDataCollectionComponent(
            id: healthDataId,
            sampleTypes: SampleTypesCollection([
                .quantity(.heartRate),
                .quantity(.bodyMass)
            ]),
            optionalSampleTypes: SampleTypesCollection(),
            historicalDataCollection: historicalCollection
        ))
        try await healthDataComponent.update(on: database)

        // Schedule: informational shown once on enrollment
        try await ComponentFixtures.createSchedule(
            on: database,
            componentId: informationalId,
            scheduleDefinition: .once(.event(.enrollment)),
            completionPolicy: .anytime
        )

        // Schedule: questionnaire repeats weekly
        try await ComponentFixtures.createSchedule(
            on: database,
            componentId: questionnaireId,
            scheduleDefinition: .repeated(.weekly(interval: 1, weekday: .monday, hour: 8, minute: 30, second: 0)),
            completionPolicy: .sameDay
        )

        // Schedule: questionnaire triggered after welcome article completed
        try await ComponentFixtures.createSchedule(
            on: database,
            componentId: questionnaireId,
            scheduleDefinition: .once(.event(.completedTask(componentId: informationalId))),
            completionPolicy: .anytime
        )

        return studyId
    }

    // MARK: - Verification

    private func verifyFullBundle(_ bundle: StudyBundle, studyId: UUID) throws { // swiftlint:disable:this function_body_length
        let definition = bundle.studyDefinition
        let enUS = Locale(identifier: "en-US")

        // Study metadata
        #expect(definition.id == studyId)
        #expect(definition.metadata.title[.enUS] == "Bundle Test Study")
        #expect(definition.metadata.consentFileRef != nil)
        #expect(definition.studyRevision == 1)

        // Components
        #expect(definition.components.count == 3)
        #expect(definition.componentSchedules.count == 3)

        // Consent text
        let consentRef = try #require(definition.metadata.consentFileRef)
        let consentText = try #require(bundle.consentText(for: consentRef, in: enUS, fallbackLocale: nil))
        #expect(consentText == "---\ntitle: Informed Consent\nversion: 1.0.0\n---\n# Informed Consent\n\nPlease read carefully.")

        // Informational component
        let informationalDef = try #require(definition.components.first(where: {
            if case .informational = $0 {
                return true
            }
            return false
        }))
        #expect(bundle.displayTitle(for: informationalDef, in: enUS) == "Welcome")
        #expect(bundle.displaySubtitle(for: informationalDef, in: enUS) == "Introduction")

        // Questionnaire component
        let questionnaireDef = try #require(definition.components.first(where: {
            if case .questionnaire = $0 {
                return true
            }
            return false
        }))
        #expect(bundle.displayTitle(for: questionnaireDef, in: enUS) == "Daily Survey")

        // Health data component
        let healthData = try #require(definition.components.lazy.compactMap {
            if case .healthDataCollection(let data) = $0 {
                return data
            }
            return nil
        }.first)
        #expect(healthData.sampleTypes.contains(.quantity(.heartRate)))
        #expect(healthData.sampleTypes.contains(.quantity(.bodyMass)))
        #expect(healthData.sampleTypes.count == 2)
        #expect(healthData.historicalDataCollection == .enabled(.last(numMonths: 6)))

        // Schedule: informational on enrollment
        let enrollmentSchedule = try #require(definition.componentSchedules.first {
            $0.componentId == informationalDef.id
        })
        #expect(enrollmentSchedule.scheduleDefinition == .once(.event(.enrollment)))
        #expect(enrollmentSchedule.completionPolicy == .anytime)

        // Schedule: questionnaire repeats weekly
        let weeklySchedule = try #require(definition.componentSchedules.first {
            $0.componentId == questionnaireDef.id
                && $0.scheduleDefinition == .repeated(.weekly(interval: 1, weekday: .monday, hour: 8, minute: 30, second: 0))
        })
        #expect(weeklySchedule.completionPolicy == .sameDay)

        // Schedule: questionnaire triggered after welcome article completed
        let afterWelcomeSchedule = try #require(definition.componentSchedules.first {
            $0.scheduleDefinition == .once(.event(.completedTask(componentId: informationalDef.id)))
        })
        #expect(afterWelcomeSchedule.componentId == questionnaireDef.id)
        #expect(afterWelcomeSchedule.completionPolicy == .anytime)
    }

    // MARK: - Extraction

    /// Extracts ZIP data to a temporary directory and loads it as a `StudyBundle`.
    private func extractStudyBundle(from zipData: Data) throws -> StudyBundle {
        let archive = try Archive(data: zipData, accessMode: .read)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        for entry in archive where entry.type != .directory {
            let destinationURL = tempDir.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var fileData = Data()
            _ = try archive.extract(entry) { chunk in fileData.append(chunk) }
            try fileData.write(to: destinationURL)
        }

        let contents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        let bundleURL = try #require(contents.first(where: { $0.pathExtension == "studybundle" }))

        return try StudyBundle(bundleUrl: bundleURL)
    }
}
