// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Fluent
import Foundation
import SQLKit
import TroveAPIServer


struct ExportMembership: Codable, Sendable {
    typealias Versions = Components.Schemas.StudyDataVersions
    let studyID: UUID
    let id: UUID
    let capturedAt: Date
    let versions: Versions
    let outputs: [StudyDataQuery.Output]
    let tasks: [TaskExportMember]
    let grants: Set<UUID>
    let revisions: [UUID: [Int]]
    let enrollmentEnds: [UUID: Date]
    let receiving: Set<UUID>

    var manifest: Components.Schemas.FrozenExport {
        .init(
            id: id.uuidString,
            studyId: studyID.uuidString,
            versions: versions,
            capturedAt: capturedAt,
            status: .queued,
            outputCount: outputs.count + tasks.reduce(0) { $0 + ($1.completion == nil ? 1 : 2) },
            projection: "study-results-v2",
            codebook: [
                "One FHIR Bundle per line, in this order: clinical events, published task definitions, task occurrences.",
                "A definitions line holds the protocol PlanDefinition, its questionnaire ActivityDefinitions and their exact Questionnaires.",
                "A task line holds one Grove Study Questionnaire Task. A completed Task links its QuestionnaireResponse version in the same line.",
                "Task status is the state at capture: ready, completed, failed or cancelled.",
                "A ready Task whose window ended counts as missed at capture.",
                "A response authored or a failure recorded within the window can still be accepted later while the enrollment is open.",
                "A failed Task was attempted in its session but could not be completed; lastModified is the failure time the device reported.",
                "That time can lie up to five minutes after server time; lastModified is raised to authoredOn when earlier.",
                "A completed Task's lastModified is when the server accepted the response, which can follow the window end.",
                "It can precede the response's authored time by up to five minutes when the device clock runs ahead.",
                "authoredOn is when the server recorded the assignment; lastModified is when the status last changed, and never before authoredOn.",
                "A performance window without an end has no deadline; such an occurrence is never missed.",
                "A cancelled Task with status reason excused was released by the study; lastModified is the excusal time.",
                "An excusal or revision adoption after the performance window ended leaves the Task ready, so it counts as missed.",
                "Task lines of unchanged data are identical in every export.",
                "A definitions line holds the Questionnaires of the exported occurrences. Record line checksums identify one execution.",
                "A cancelled Task without a status reason stopped when the participant adopted a later revision at lastModified.",
                "Line numbers start at one. Member SHA-256 excludes the line feed. File SHA-256 includes every line feed.",
                "Subject identifiers use the study enrollment namespace. Output versions identify exact source nodes within this study.",
                "Publication revisions identify the consent-backed grants and the task revisions. isCurrent describes the instant of capture."
            ],
            exclusions: [
                "Withdrawn enrollments, their tasks and retracted records are ineligible.",
                "Recording bytes require their separate authorized download.",
                "Device unit identifiers follow the study publication disclosure policy.",
                "Original authoring files, responses still being answered and provider coverage are excluded.",
                "A QuestionnaireResponse omits the submitted author and source; the receipt supplies its identity, subject and version."
            ]
        )
    }

    static func selection(
        study: UUID,
        versions: StudyDataQuery.Versions,
        ids: [UUID]?, // swiftlint:disable:this discouraged_optional_collection
        tasks: [TaskExportMember],
        on database: any Database
    ) async throws -> StudyDataFence {
        guard database.inTransaction, let sql = database as? any SQLDatabase else { throw AuditError.transactionRequired }
        let eligible = StudyDataQuery.eligibleOutputs(studyID: study, versions: versions, on: sql)
        let subset: SQLQueryString
        if let ids {
            subset = ids.isEmpty ? "WHERE 1 = 0" : "WHERE node_id IN (\(binds: ids))"
        } else {
            subset = ""
        }
        let rows = try await sql.raw("""
            WITH eligible AS (\(eligible)) SELECT * FROM eligible \(subset)
            ORDER BY received_at DESC, event_id DESC, node_id DESC LIMIT 1025
            """)
                .all()
        let outputs = try rows.map(StudyDataQuery.Output.init(row:))
        guard outputs.count <= StudyDataQuery.maximumPageOutputs, Set(outputs.map(\.eventID)).count <= 100,
              tasks.count <= TaskExportMember.maximumMembers else {
            throw ServerError.conflict("Export exceeds the bounded snapshot capacity")
        }
        if let ids, Set(outputs.map(\.nodeID)) != Set(ids) { throw ServerError.forbidden }
        let page = StudyDataQuery.Page(outputs: outputs, nextBefore: nil)
        return try await StudyDataQuery(database: database).fence(page, studyID: study, versions: versions, tasks: tasks)
    }

    static func ends(_ fence: StudyDataFence) -> [UUID: Date] {
        Dictionary(uniqueKeysWithValues: fence.enrollments.compactMap { enrollment in enrollment.endsAt.map { (enrollment.id, $0) } })
    }

    func currentFence(on database: any Database) async throws -> StudyDataFence {
        let live = try await Self.selection(study: studyID, versions: .history, ids: outputs.map(\.nodeID), tasks: tasks, on: database)
        let devices = try await StudyDeviceUnitDisclosure.receivingEvents(Set(outputs.map(\.eventID)), studyID: studyID, on: database)
        guard grants.isSubset(of: Set(live.grants.map(\.id))), receiving.isSubset(of: devices) else { throw ServerError.forbidden }
        // Corrections can change currentness. Keep the captured flags while requiring current disclosure permission.
        return .init(
            page: .init(outputs: outputs, nextBefore: nil),
            grants: live.grants.filter { grants.contains($0.id) },
            enrollments: live.enrollments.map { .init(id: $0.id, endsAt: enrollmentEnds[$0.id]) }
        )
    }
}
