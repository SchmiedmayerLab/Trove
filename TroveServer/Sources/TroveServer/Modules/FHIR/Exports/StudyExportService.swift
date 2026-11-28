// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Fluent
import Foundation
import SQLKit
import TroveAPIServer


extension StudyService {
    private static func exportAuthority(_ study: Study, actor: AuthContext, on database: any Database) async throws {
        guard let group = try await Group.find(study.$group.id, on: database),
              actor.principalInvestigatorGroups.contains(group.name) else { throw ServerError.forbidden }
        try actor.checkDataAccess(groupName: group.name)
        guard actor.tokenExpiresAt.map({ $0 > Date() }) ?? true else { throw ServerError.forbidden }
    }

    // swiftlint:disable:next function_parameter_count
    private static func exportAudit(
        _ action: AuditEvent.Action,
        snapshot: ExportMembership,
        actor: AuthContext,
        study: Study,
        part: String?,
        on database: any Database
    ) async throws {
        let event = AuditEvent(
            context: actor.auditContext,
            action: action,
            scope: .study(studyID: snapshot.studyID, groupID: study.$group.id),
            target: .init(id: snapshot.id, version: part)
        )
        if action.isDisclosure {
            try await AuditRepository.recordDisclosureIntent(event, on: database)
        } else {
            try await AuditRepository.recordMutation(event, on: database)
        }
    }

    private static func capture(
        studyID: UUID, versions: ExportMembership.Versions, tasks: [TaskExportMember], fence: StudyDataFence, on database: any Database
    ) async throws -> ExportMembership {
        try await ExportMembership(
            studyID: studyID,
            id: UUID(),
            capturedAt: Date(),
            versions: versions,
            outputs: fence.page.outputs,
            tasks: tasks,
            grants: Set(fence.grants.map(\.id)),
            revisions: Dictionary(grouping: fence.grants, by: \.nodeID).mapValues { $0.map(\.revision) },
            enrollmentEnds: ExportMembership.ends(fence),
            receiving: StudyDeviceUnitDisclosure.receivingEvents(Set(fence.page.outputs.map(\.eventID)), studyID: studyID, on: database)
        )
    }

    /// Runs one export transaction. `prefetch` reads object storage after the authority check and before any lock is taken.
    private func exportTransaction<Value: Sendable>(
        studyID: UUID,
        prefetch: @escaping @Sendable () async throws -> TaskExportObjects = { TaskExportObjects() },
        operation: @escaping @Sendable (AuthContext, any Database, any SQLDatabase, TaskExportObjects) async throws -> Value
    ) async throws -> Value {
        let actor = try AuthContext.checkIsResearcher()
        let study = try await authorizationService.checkResearcherHasStudyDataAccess(studyID, actor: actor, on: repository.database)
        try await Self.exportAuthority(study, actor: actor, on: repository.database)
        guard !repository.database.inTransaction else { throw AuditError.disclosureInsideTransaction }
        let objects = try await prefetch()
        return try await repository.database.transaction { database in
            guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
            let result = try await operation(actor, database, sql, objects)
            try await Self.exportAuthority(study, actor: actor, on: database)
            return result
        }
    }

    /// Creation reads only the publication archives; an existing request reads none.
    private func creationPrefetch(studyID: UUID, request: UUID) -> @Sendable () async throws -> TaskExportObjects {
        let artifacts = ArtifactStore(database: repository.database, storage: exportStorage)
        let database = repository.database
        return {
            guard let sql = database as? any SQLDatabase else {
                return TaskExportObjects()
            }
            let existing = try await sql.raw("""
                SELECT id FROM study_export_jobs WHERE study_id = \(bind: studyID) AND request_id = \(bind: request)
                """)
                .all()
            guard existing.isEmpty else {
                return TaskExportObjects()
            }
            let tasks = try await database.transaction { try await TaskExportMember.select(study: studyID, ids: nil, on: $0) }
            return try await TaskExportObjects.fetch(tasks, using: artifacts)
        }
    }

    func createStudyExport(studyID: UUID, input: Components.Schemas.FrozenExportRequest) async throws -> Components.Schemas.FrozenExport {
        let request = try input.requestId.requireId()
        let prefetch = creationPrefetch(studyID: studyID, request: request)
        return try await exportTransaction(studyID: studyID, prefetch: prefetch) { actor, database, sql, objects in
            if let existing = try await sql.raw("""
                SELECT id FROM study_export_jobs WHERE study_id = \(bind: studyID) AND request_id = \(bind: request)
                """)
                    .first() {
                let id = try existing.decode(column: "id", as: UUID.self)
                let job = try await self.loadExport(studyID: studyID, id: id, actor: actor, on: database, sql: sql)
                guard job.snapshot.versions == input.versions else { throw ServerError.conflict("Export request ID already used") }
                try await Self.exportAudit(.exportDisclosure, snapshot: job.snapshot, actor: actor, study: job.study, part: "manifest", on: database)
                return try await job.manifest()
            }
            let observed = try await TaskExportMember.select(study: studyID, ids: nil, on: database)
            let fence = try await ExportMembership.selection(
                study: studyID, versions: input.versions == .history ? .history : .current, ids: nil, tasks: observed, on: database
            )
            let study = try await self.repository.lockStudy(id: studyID, on: database)
            try await Self.exportAuthority(study, actor: actor, on: database)
            // Every task member is read again under the participant and enrollment locks.
            let tasks = try await TaskExportMember.select(study: studyID, ids: nil, on: database)
            guard tasks == observed else { throw ServerError.conflict("Study tasks changed; retry the same request") }
            var cache = TaskExportMember.AuthorizationCache()
            for task in tasks { try await task.authorize(group: study.$group.id, cache: &cache, on: database) }
            _ = try await self.taskPublications(tasks, objects: objects, on: database)
            let snapshot = try await Self.capture(studyID: studyID, versions: input.versions, tasks: tasks, fence: fence, on: database)
            try await self.checkExportRows(fence, studyID: studyID, database: database)
            let bytes = try JSONEncoder().encode(snapshot)
            guard let inserted = try await sql.raw("""
                INSERT INTO study_export_jobs (id, study_id, request_id, membership)
                VALUES (\(bind: snapshot.id), \(bind: studyID), \(bind: request), \(bind: bytes))
                ON CONFLICT (study_id, request_id) DO NOTHING RETURNING id
                """)
                    .first(), try inserted.decode(column: "id", as: UUID.self) == snapshot.id else {
                throw ServerError.conflict("Concurrent export creation; retry the same request")
            }
            try await Self.exportAudit(.exportCreated, snapshot: snapshot, actor: actor, study: study, part: nil, on: database)
            try await Self.exportAudit(.exportDisclosure, snapshot: snapshot, actor: actor, study: study, part: "manifest", on: database)
            return snapshot.manifest
        }
    }

    private func checkExportRows(_ fence: StudyDataFence, studyID: UUID, database: any Database) async throws {
        let store = StudyDataExportStore(database: database, limits: exportLimits)
        let query = StudyDataQuery(database: database)
        let grants = Dictionary(grouping: fence.grants, by: \.nodeID)
        for (eventID, outputs) in Dictionary(grouping: fence.page.outputs, by: \.eventID) {
            let event = try await store.retainedEvent(id: eventID)
            for output in outputs {
                for grant in grants[output.nodeID] ?? [] {
                    try await query.requireEveryRowSelected(event, output: output, grant: grant, studyID: studyID, otherwise: .forbidden)
                }
            }
        }
    }

    private func loadExport(
        studyID: UUID, id: UUID, actor: AuthContext, on database: any Database, sql: any SQLDatabase
    ) async throws -> AuthorizedExport {
        guard let row = try await sql.raw("""
            SELECT membership FROM study_export_jobs WHERE study_id = \(bind: studyID) AND id = \(bind: id)
            """)
                .first() else { throw ServerError.notFound("Export not found") }
        let snapshot = try JSONDecoder().decode(ExportMembership.self, from: row.decode(column: "membership", as: Data.self))
        guard snapshot.studyID == studyID, snapshot.id == id else { throw ServerError.unexpectedError }
        let fence = try await snapshot.currentFence(on: database)
        let study = try await repository.lockStudy(id: studyID, on: database)
        try await Self.exportAuthority(study, actor: actor, on: database)
        try await TaskExportMember.check(snapshot.tasks, study: study, on: database)
        try await checkExportRows(fence, studyID: studyID, database: database)
        return AuthorizedExport(snapshot: snapshot, fence: fence, study: study, sql: sql)
    }

    func withStudyExport<Value: Sendable>(
        studyID: UUID,
        id: UUID,
        part: String,
        execute: Bool = false,
        read: @escaping @Sendable (AuthorizedExport) async throws -> Value
    ) async throws -> Value {
        let artifacts = ArtifactStore(database: repository.database, storage: exportStorage)
        let sql = repository.database as? any SQLDatabase
        let limits = exportLimits
        let prefetch: @Sendable () async throws -> TaskExportObjects = {
            guard execute, let sql, let row = try await sql.raw("""
                SELECT membership FROM study_export_jobs WHERE study_id = \(bind: studyID) AND id = \(bind: id)
                """)
                    .first(),
                  try await sql.raw("SELECT id FROM study_export_files WHERE id = \(bind: id)").all().isEmpty else { return TaskExportObjects() }
            let snapshot = try JSONDecoder().decode(ExportMembership.self, from: row.decode(column: "membership", as: Data.self))
            return try await TaskExportObjects.fetch(snapshot.tasks, using: artifacts, responseBudget: limits.pageBytes)
        }
        return try await exportTransaction(studyID: studyID, prefetch: prefetch) { actor, database, sql, objects in
            let job = try await self.loadExport(studyID: studyID, id: id, actor: actor, on: database, sql: sql)
            if execute, try await job.manifest().status == .queued {
                try await self.execute(job, studyID: studyID, actor: actor, objects: objects, on: database)
            }
            let value = try await read(job)
            try await Self.exportAudit(.exportDisclosure, snapshot: job.snapshot, actor: actor, study: job.study, part: part, on: database)
            return value
        }
    }

    /// Reads the exact archived definitions of every revision the task members name.
    private func taskPublications(
        _ tasks: [TaskExportMember], objects: TaskExportObjects, on database: any Database
    ) async throws -> [UUID: TaskExportPublication] {
        let artifacts = ArtifactStore(database: database, storage: exportStorage)
        var result: [UUID: TaskExportPublication] = [:]
        for (id, members) in Dictionary(grouping: tasks.map(\.instrument), by: \.publicationID) {
            result[id] = try await TaskExportPublication.load(members, objects: objects, using: artifacts)
        }
        return result
    }

    /// Writes the export file once, under the transaction that rechecked every member.
    private func execute(
        _ job: AuthorizedExport, studyID: UUID, actor: AuthContext, objects: TaskExportObjects, on database: any Database
    ) async throws {
        let page = try await StudyDataExportStore(database: database, limits: exportLimits).page(
            studyID: studyID,
            versions: job.snapshot.versions == .history ? .history : .current,
            evidence: job.fence,
            recordedAt: job.snapshot.capturedAt,
            frozen: job.snapshot
        )
        var file = try FrozenExportFile(snapshot: job.snapshot, page: page)
        let artifacts = ArtifactStore(database: database, storage: exportStorage)
        let publications = try await taskPublications(job.snapshot.tasks, objects: objects, on: database)
        for (id, publication) in publications.sorted(by: { $0.value.revision < $1.value.revision }) {
            let line = try StudyTaskProjection.definitions(publication, study: studyID, publicationID: id, maximumBytes: exportLimits.bundleBytes)
            try file.append(definitions: line, publication: id, revision: publication.revision, limit: exportLimits.pageBytes)
        }
        for task in job.snapshot.tasks {
            guard let publication = publications[task.instrument.publicationID],
                  let questionnaire = publication.questionnaires[task.instrument.componentID] else { throw ServerError.unexpectedError }
            let pins = try StudyTaskDefinitions.resolve(
                publication.graph,
                study: studyID,
                revision: task.instrument.revision,
                component: task.instrument.componentID,
                questionnaire: questionnaire.canonical
            )
            let response = try await task.acceptedResponse(group: job.study.$group.id, objects: objects, using: artifacts)
            let line = try StudyTaskProjection.delivery(
                task, pins: pins, questionnaire: questionnaire.canonical, response: response, maximumBytes: exportLimits.bundleBytes
            )
            try file.append(task: task, line: line, limit: exportLimits.pageBytes)
        }
        file.finish()
        try await file.insert(id: job.snapshot.id, on: job.sql)
        try await Self.exportAudit(.exportExecuted, snapshot: job.snapshot, actor: actor, study: job.study, part: nil, on: database)
    }
}
