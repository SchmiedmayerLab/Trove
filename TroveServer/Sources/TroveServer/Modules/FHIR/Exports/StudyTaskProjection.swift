// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import TroveAPIServer


/// Projects the task store into the Grove Study Exchange. Inputs come from the recorded assignment,
/// the accepted result receipt and the exact definitions retained with the published revision.
enum StudyTaskProjection {
    private static let profiles = "https://grovealliance.org/fhir/study/StructureDefinition/"
    private static let inputSystem = "https://grovealliance.org/fhir/study/CodeSystem/grove-study-task-input"
    private static let sdc = "http://hl7.org/fhir/uv/sdc/CodeSystem/temp"
    private static let statusReasonSystem = "https://grovealliance.org/fhir/study/CodeSystem/grove-study-task-status-reason"
    private static let responseProfile = "https://grovealliance.org/fhir/questionnaire/StructureDefinition/grove-questionnaire-response"

    static func root(_ study: UUID) -> String {
        "urn:trove:study:" + study.uuidString.lowercased()
    }

    /// One collection Bundle with the Task and, for a completed occurrence, its version-linked QuestionnaireResponse.
    static func delivery(
        _ member: TaskExportMember,
        pins: StudyTaskDefinitions.Pins,
        questionnaire: String,
        response: Data?,
        maximumBytes: Int = StudyExportLimits.standard.bundleBytes
    ) throws -> Data {
        let study = member.instrument.studyID
        let resource = try json(task(member, pins: pins, questionnaire: questionnaire))
        var entries: [StudyProjectionJSON] = [try .object(["fullUrl": .string(root(study) + ":tasks:" + member.occurrence), "resource": resource])]
        switch (member.status, member.completion, response) {
        case let (.completed, completion?, bytes?):
            entries.append(try .object([
                "fullUrl": .string("urn:uuid:" + completion.id.uuidString.lowercased()),
                "resource": .object(result(member, completion: completion, questionnaire: questionnaire, bytes: bytes))
            ]))
        case (.ready, nil, nil), (.failed, nil, nil), (.cancelled, nil, nil):
            break
        default:
            throw ServerError.unexpectedError
        }
        return try StudyProjectionJSON.object([
            "resourceType": .string("Bundle"),
            "id": .string(member.occurrence),
            "type": .string("collection"),
            "entry": .array(entries)
        ])
            .encoded(maximumBytes: maximumBytes)
    }

    /// One collection Bundle with the protocol, the questionnaire components and their exact Questionnaires.
    static func definitions(
        _ publication: TaskExportPublication, study: UUID, publicationID: UUID, maximumBytes: Int = StudyExportLimits.standard.bundleBytes
    ) throws -> Data {
        let graph = try StudyProjectionJSON.readResult(publication.graph)
        guard var entries = graph["entry"]?.array else { throw StudyTaskDefinitions.invalid }
        for component in publication.questionnaires.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let questionnaire = publication.questionnaires[component] else { throw ServerError.unexpectedError }
            entries.append(try .object([
                "fullUrl": .string("urn:uuid:" + component.uuidString.lowercased()),
                "resource": StudyProjectionJSON.readResult(questionnaire.bytes)
            ]))
        }
        return try StudyProjectionJSON.object([
            "resourceType": .string("Bundle"),
            "id": .string(publicationID.uuidString.lowercased()),
            "type": .string("collection"),
            "entry": .array(entries)
        ])
            .encoded(maximumBytes: maximumBytes)
    }

    private static func json(_ object: [String: Any]) throws -> StudyProjectionJSON {
        try .readResult(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
    }

    private static func coding(_ system: String, _ code: String) -> [String: Any] {
        ["coding": [["system": system, "code": code]]]
    }

    private static func reference(_ type: String, _ system: String, _ value: String) -> [String: Any] {
        ["type": type, "identifier": ["system": system, "value": value]]
    }

    private static func task(_ member: TaskExportMember, pins: StudyTaskDefinitions.Pins, questionnaire: String) throws -> [String: Any] {
        let dates = TroveDateTranscoder()
        let root = root(member.instrument.studyID)
        let subject = TaskExportMember.subject(study: member.instrument.studyID, enrollment: member.enrollment)
        guard [pins.activity, pins.plan, questionnaire].allSatisfy(StudyTaskDefinitions.pinnedCanonical),
              member.assignedAt <= member.lastModified else { throw ServerError.conflict("Invalid task assignment evidence") }
        // A window without an end has no deadline; its start alone is stated.
        var window = ["start": try dates.encode(member.window.start)]
        window["end"] = try member.window.end.map(dates.encode)
        var task: [String: Any] = [
            "resourceType": "Task",
            "id": member.occurrence,
            "meta": ["profile": [profiles + "grove-study-questionnaire-task"]],
            "identifier": [["system": root + ":occurrences", "value": member.occurrence]],
            "instantiatesCanonical": pins.activity,
            "status": member.status.rawValue,
            "intent": "order",
            "code": coding(sdc, "complete-questionnaire"),
            "for": reference("Patient", subject.system, subject.value),
            "authoredOn": try dates.encode(member.assignedAt),
            "lastModified": try dates.encode(member.lastModified),
            "input": [
                ["type": coding(inputSystem, "performance-window"), "valuePeriod": window],
                ["type": coding(inputSystem, "enrollment"), "valueReference": reference("ResearchSubject", root + ":enrollments", subject.value)],
                ["type": coding(inputSystem, "protocol"), "valueCanonical": pins.plan],
                ["type": coding(sdc, "questionnaire"), "valueCanonical": questionnaire]
            ]
        ]
        if member.excused {
            guard member.status == .cancelled else { throw ServerError.unexpectedError }
            task["statusReason"] = coding(statusReasonSystem, "excused")
        }
        if let completion = member.completion {
            let link = "QuestionnaireResponse/" + completion.id.uuidString.lowercased() + "/_history/" + String(completion.version)
            task["output"] = [["type": coding(sdc, "questionnaire-response"), "valueReference": ["reference": link]]]
        }
        return task
    }

    private static func result(
        _ member: TaskExportMember, completion: TaskExportMember.Completion, questionnaire: String, bytes: Data
    ) throws -> [String: StudyProjectionJSON] {
        let subject = TaskExportMember.subject(study: member.instrument.studyID, enrollment: member.enrollment)
        guard bytes.count <= FHIRValidationClient.maximumBytes, FHIRValidationClient.digest(bytes) == completion.responseDigest else {
            throw ServerError.conflict("Task result checksum or size does not match")
        }
        try TaskResultEvidence.check(
            bytes, opens: member.window.start, cutoff: member.window.end, subjectSystem: subject.system, subjectValue: subject.value
        )
        guard completion.version > 0, var response = try StudyProjectionJSON.readResult(bytes).object, response["modifierExtension"] == nil,
              response["resourceType"]?.string == "QuestionnaireResponse", response["status"]?.string == "completed",
              response["questionnaire"]?.string == questionnaire, response["language"]?.string == completion.language,
              response["authored"]?.string != nil else { throw ServerError.conflict("Task result evidence does not match the assignment") }
        // The result keeps its accepted answers. Identity and version come from the receipt.
        let retained = ["resourceType", "status", "questionnaire", "language", "authored", "item", "extension", "contained"]
        response = response.filter { retained.contains($0.key) }
        let identifier = completion.id.uuidString.lowercased()
        response["id"] = try .string(identifier)
        response["subject"] = try json(reference("Patient", subject.system, subject.value))
        response["identifier"] = try json(["system": root(member.instrument.studyID) + ":task-results", "value": identifier])
        response["meta"] = try json(["versionId": String(completion.version), "profile": [responseProfile]])
        return response
    }
}
