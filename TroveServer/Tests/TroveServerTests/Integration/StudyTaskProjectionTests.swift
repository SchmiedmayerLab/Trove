// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import TroveServer


struct StudyTaskProjectionTests {
    private static let pins = StudyTaskDefinitions.Pins(activity: "https://example.org/a|1", plan: "https://example.org/p|1")

    private static func member(
        study: UUID,
        enrollment: UUID,
        status: TaskExportMember.Status,
        end: Date?,
        completion: TaskExportMember.Completion? = nil,
        excused: Bool = false
    ) throws -> TaskExportMember {
        let opened = try Date.ISO8601FormatStyle().parse("2026-08-01T09:00:00Z")
        return .init(
            occurrence: String(repeating: "a", count: 64),
            participant: UUID(),
            enrollment: enrollment,
            schedule: UUID(),
            instrument: .init(
                studyID: study, publicationID: UUID(), revision: 1, artifactID: UUID(), componentID: UUID(), baseLanguage: "de", sha256: ""
            ),
            assignedAt: opened.addingTimeInterval(-30),
            window: .init(start: opened, end: end),
            status: status,
            excused: excused,
            lastModified: completion?.acceptedAt ?? opened.addingTimeInterval(-30),
            completion: completion,
            identityHash: ""
        )
    }

    private static func accepted(study: UUID, enrollment: UUID, opened: Date) -> (Data, TaskExportMember.Completion) {
        let subjectSystem = "urn:trove:study:" + study.uuidString.lowercased() + ":participants"
        let source = Data("""
            {"resourceType":"QuestionnaireResponse","status":"completed","language":"de","questionnaire":"https://example.org/q|1",
             "subject":{"type":"Patient","identifier":{"system":"\(subjectSystem)","value":"\(enrollment.uuidString.lowercased())"}},
             "partOf":[{"reference":"Task/x"}],
             "authored":"2026-08-01T09:01:00Z","item":[{"linkId":"m","answer":[{"valueDecimal":1.230000000000000000007}]}]}
            """.utf8)
        let completion = TaskExportMember.Completion(
            id: UUID(),
            session: UUID(),
            command: UUID(),
            consent: UUID(),
            responseArtifact: UUID(),
            responseDigest: FHIRValidationClient.digest(source),
            version: 9,
            acceptedAt: opened.addingTimeInterval(61),
            language: "de",
            evidenceHashes: []
        )
        return (source, completion)
    }

    @Test
    func mismatchedResultsAreRefused() throws {
        let study = UUID()
        let enrollment = UUID()
        let opened = try Date.ISO8601FormatStyle().parse("2026-08-01T09:00:00Z")
        let (source, completion) = Self.accepted(study: study, enrollment: enrollment, opened: opened)
        let member = try Self.member(study: study, enrollment: enrollment, status: .completed, end: nil, completion: completion)
        let early = try Self.member(
            study: study, enrollment: enrollment, status: .completed, end: opened.addingTimeInterval(30), completion: completion
        )
        #expect(throws: ServerError.self) {
            try StudyTaskProjection.delivery(early, pins: Self.pins, questionnaire: "https://example.org/q|1", response: source)
        }
        #expect(throws: ServerError.self) {
            try StudyTaskProjection.delivery(member, pins: Self.pins, questionnaire: "https://example.org/q|2", response: source)
        }
        #expect(throws: ServerError.self) {
            try StudyTaskProjection.delivery(member, pins: Self.pins, questionnaire: "https://example.org/q|1", response: source + Data(" ".utf8))
        }
    }

    @Test(arguments: [false, true])
    func completedTaskLinksTheExactResultVersion(finite: Bool) throws {
        let study = UUID()
        let enrollment = UUID()
        let subjectSystem = "urn:trove:study:" + study.uuidString.lowercased() + ":participants"
        let opened = try Date.ISO8601FormatStyle().parse("2026-08-01T09:00:00Z")
        let (source, completion) = Self.accepted(study: study, enrollment: enrollment, opened: opened)
        let end = finite ? opened.addingTimeInterval(120) : nil
        let member = try Self.member(study: study, enrollment: enrollment, status: .completed, end: end, completion: completion)
        let bytes = try StudyTaskProjection.delivery(member, pins: Self.pins, questionnaire: "https://example.org/q|1", response: source)
        let entries = try #require(try StudyProjectionJSON.readResult(bytes)["entry"]?.array)
        let task = try #require(entries.first?["resource"])
        let response = try #require(entries.last?["resource"])
        let window = try #require(task["input"]?.array?.first?["valuePeriod"])
        #expect(window["start"]?.string == "2026-08-01T09:00:00.000000Z")
        #expect((window["end"] == nil) == !finite)
        #expect(task["input"]?.array?.count == 4)
        #expect(task["authoredOn"]?.string == "2026-08-01T08:59:30.000000Z")
        #expect(task["lastModified"]?.string == "2026-08-01T09:01:01.000000Z")
        #expect(response["meta"]?["versionId"]?.string == "9")
        #expect(response["partOf"] == nil)
        let reference = task["output"]?.array?.first?["valueReference"]?["reference"]?.string
        #expect(reference == "QuestionnaireResponse/\(completion.id.uuidString.lowercased())/_history/9")
        #expect(response["subject"]?["identifier"]?["system"]?.string == subjectSystem)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.contains("1.230000000000000000007") && !text.contains("\\/"))
    }

    @Test
    func excusedTaskCarriesItsStatusReason() throws {
        let member = try Self.member(study: UUID(), enrollment: UUID(), status: .cancelled, end: nil, excused: true)
        let bytes = try StudyTaskProjection.delivery(member, pins: Self.pins, questionnaire: "https://example.org/q|1", response: nil)
        let task = try #require(try StudyProjectionJSON.readResult(bytes)["entry"]?.array?.first?["resource"])
        #expect(task["statusReason"]?["coding"]?.array?.first?["code"]?.string == "excused")
        let ready = try Self.member(study: UUID(), enrollment: UUID(), status: .ready, end: nil, excused: true)
        #expect(throws: ServerError.self) {
            try StudyTaskProjection.delivery(ready, pins: Self.pins, questionnaire: "https://example.org/q|1", response: nil)
        }
    }

    @Test(arguments: [TaskExportMember.Status.ready, .cancelled])
    func openTasksCarryNoResult(status: TaskExportMember.Status) throws {
        let member = try Self.member(study: UUID(), enrollment: UUID(), status: status, end: nil)
        let bytes = try StudyTaskProjection.delivery(member, pins: Self.pins, questionnaire: "https://example.org/q|1", response: nil)
        let entries = try #require(try StudyProjectionJSON.readResult(bytes)["entry"]?.array)
        #expect(entries.count == 1)
        let task = try #require(entries.first?["resource"])
        #expect(task["status"]?.string == status.rawValue && task["output"] == nil)
        #expect(task["input"]?.array?.first?["valuePeriod"]?["end"] == nil)
        #expect(throws: ServerError.self) {
            try StudyTaskProjection.delivery(member, pins: Self.pins, questionnaire: "https://example.org/q|1", response: Data("{}".utf8))
        }
        let unpinned = StudyTaskDefinitions.Pins(activity: "https://example.org/a", plan: Self.pins.plan)
        #expect(throws: ServerError.self) {
            try StudyTaskProjection.delivery(member, pins: unpinned, questionnaire: "https://example.org/q|1", response: nil)
        }
    }
}
