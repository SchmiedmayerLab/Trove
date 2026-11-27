// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Fluent
import Foundation
import SQLKit
import TroveAPIServer


struct FrozenExportFile {
    var manifest: Components.Schemas.FrozenExport
    var members: [Components.Schemas.FrozenExportMember] = []
    var bytes = Data()

    init(snapshot: ExportMembership, page: Components.Schemas.StudyDataPage) throws {
        manifest = snapshot.manifest
        let grouped = Dictionary(grouping: snapshot.outputs, by: \.eventID)
        var seen = Set<UUID>()
        let ordered = snapshot.outputs.compactMap { seen.insert($0.eventID).inserted ? grouped[$0.eventID] : nil }
        guard ordered.count == page.records.count else { throw ServerError.unexpectedError }
        for (outputs, record) in zip(ordered, page.records) {
            guard let first = outputs.first, outputs.count == record.outputs.count,
                  let line = Data(base64Encoded: record.bundleBase64), !line.isEmpty, !line.contains(10), !line.contains(13) else {
                throw ServerError.unexpectedError
            }
            bytes.append(line)
            bytes.append(10)
            let versions = outputs.map { node in
                FHIRValidationClient.digest(Data("\(snapshot.studyID.uuidString)/\(node.nodeID.uuidString)".utf8))
            }
            members.append(.init(
                line: members.count + 1,
                kind: .record,
                bundleId: record.id,
                subjectSystem: "urn:trove:study:" + snapshot.studyID.uuidString.lowercased() + ":participants",
                subjectId: first.enrollmentID.uuidString.lowercased(),
                versions: versions,
                outputs: record.outputs,
                sha256: FHIRValidationClient.digest(line),
                byteCount: line.count,
                publicationRevisions: Array(Set(outputs.flatMap { snapshot.revisions[$0.nodeID] ?? [] })).sorted()
            ))
        }
    }

    private mutating func append(line: Data, limit: Int) throws {
        guard !line.isEmpty, !line.contains(10), !line.contains(13), line.count < limit - bytes.count else {
            throw StudyProjectionJSON.Failure.outputTooLarge
        }
        bytes.append(line)
        bytes.append(10)
    }

    mutating func append(definitions line: Data, publication: UUID, revision: Int, limit: Int) throws {
        try append(line: line, limit: limit)
        members.append(.init(
            line: members.count + 1,
            kind: .definitions,
            bundleId: publication.uuidString.lowercased(),
            versions: [],
            outputs: [],
            sha256: FHIRValidationClient.digest(line),
            byteCount: line.count,
            publicationRevisions: [revision]
        ))
    }

    mutating func append(task: TaskExportMember, line: Data, limit: Int) throws {
        try append(line: line, limit: limit)
        let subject = TaskExportMember.subject(study: task.instrument.studyID, enrollment: task.enrollment)
        members.append(.init(
            line: members.count + 1,
            kind: .task,
            bundleId: task.occurrence,
            subjectSystem: subject.system,
            subjectId: subject.value,
            taskStatus: Components.Schemas.FrozenExportMember.TaskStatusPayload(rawValue: task.status.rawValue),
            taskStatusReason: task.excused ? .excused : nil,
            versions: task.completion.map { ["QuestionnaireResponse/" + $0.id.uuidString.lowercased() + "/_history/" + String($0.version)] } ?? [],
            outputs: [],
            sha256: FHIRValidationClient.digest(line),
            byteCount: line.count,
            publicationRevisions: [task.instrument.revision]
        ))
    }

    mutating func finish() {
        manifest.status = .ready
        manifest.byteCount = bytes.count
        manifest.recordCount = members.count
        manifest.sha256 = FHIRValidationClient.digest(bytes)
    }

    func insert(id: UUID, on sql: any SQLDatabase) async throws {
        let summary = try JSONEncoder().encode(manifest)
        let index = try JSONEncoder().encode(members)
        try await sql.raw("""
            INSERT INTO study_export_files (id, manifest, members, ndjson)
            VALUES (\(bind: id), \(bind: summary), \(bind: index), \(bind: bytes))
            """)
                .run()
    }
}
