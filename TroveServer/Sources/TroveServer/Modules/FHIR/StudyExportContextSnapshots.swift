//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract


/// Same minimal ResearchStudy/PlanDefinition/ResearchSubject meanings as Grove's StudyEnrollment,
/// with receiver-derived addresses rather than producer-keyed immutable snapshot claims.
struct StudyExportContextSnapshots {
    let studies: [StudyEnrollment: String]
    let entries: [StudyProjectionJSON]

    static func build(grants: [StudyPointExport.Grant], context: StudyPointExport.Context) throws -> Self {
        let enrollments = Set(grants.map(\.enrollment)).sorted {
            let left = $0.protocolURL.value?.url.absoluteString ?? ""
            let right = $1.protocolURL.value?.url.absoluteString ?? ""
            return left == right ? $0.protocolVersion < $1.protocolVersion : left < right
        }
        guard enrollments.count <= StudyPointExport.maximumEntries / 3 else { throw StudyProjectionJSON.Failure.outputTooLarge }
        var studies: [StudyEnrollment: String] = [:]
        var entries: [StudyProjectionJSON] = []
        for enrollment in enrollments {
            let planID = UUID().uuidString.lowercased(), studyID = UUID().uuidString.lowercased(), subjectID = UUID().uuidString.lowercased()
            let planURL = "urn:uuid:" + planID, studyURL = "urn:uuid:" + studyID
            entries.append(try entry(id: planID, resource: plan(enrollment)))
            entries.append(try entry(id: studyID, resource: study(enrollment, protocolReference: planURL)))
            entries.append(try entry(id: subjectID, resource: researchSubject(enrollment, studyReference: studyURL, context: context)))
            studies[enrollment] = studyURL
        }
        return .init(studies: studies, entries: entries)
    }

    private static func entry(id: String, resource: StudyProjectionJSON) throws -> StudyProjectionJSON {
        guard var members = resource.object else { throw FHIRValidationClient.invalid }
        members["id"] = try .string(id)
        return try .object(["fullUrl": .string("urn:uuid:" + id), "resource": .object(members)])
    }

    private static func plan(_ enrollment: StudyEnrollment) throws -> StudyProjectionJSON {
        guard let url = enrollment.protocolURL.value?.url.absoluteString,
              enrollment.protocolURL.value?.version == nil, !url.isEmpty,
              !enrollment.protocolVersion.isEmpty, enrollment.protocolVersion.utf8.count <= 128 else {
            throw FHIRValidationClient.invalid
        }
        return try .object([
            "resourceType": .string("PlanDefinition"), "status": .string("active"),
            "url": .string(url), "version": .string(enrollment.protocolVersion)
        ])
    }

    private static func study(_ enrollment: StudyEnrollment, protocolReference: String) throws -> StudyProjectionJSON {
        try .object([
            "resourceType": .string("ResearchStudy"), "status": .string("active"),
            "identifier": .array([StudyPointExport.identifier(system: enrollment.study.system.rawValue, value: enrollment.study.value)]),
            "protocol": .array([StudyPointExport.reference(protocolReference)])
        ])
    }

    private static func researchSubject(
        _ enrollment: StudyEnrollment, studyReference: String, context: StudyPointExport.Context
    ) throws -> StudyProjectionJSON {
        let ended = context.enrollmentEndsAt.map { $0 <= context.recordedAt } ?? false
        var resource: [String: StudyProjectionJSON] = try [
            "resourceType": .string("ResearchSubject"), "status": .string(ended ? "off-study" : "on-study"),
            "identifier": .array([StudyPointExport.identifier(system: enrollment.enrollment.system.rawValue, value: enrollment.enrollment.value)]),
            "study": StudyPointExport.reference(studyReference),
            "individual": .object([
                "type": .string("Patient"),
                "identifier": StudyPointExport.identifier(system: context.subject.system.rawValue, value: context.subject.value)
            ])
        ]
        if let end = context.enrollmentEndsAt {
            resource["period"] = try .object(["end": .string(StudyPointExport.timestamp(end))])
        }
        return .object(resource)
    }
}
