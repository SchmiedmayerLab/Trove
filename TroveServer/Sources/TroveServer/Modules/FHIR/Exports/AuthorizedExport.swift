// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import SQLKit
import TroveAPIServer


struct AuthorizedExport: Sendable {
    let snapshot: ExportMembership
    let fence: StudyDataFence
    let study: Study
    let sql: any SQLDatabase

    func manifest() async throws -> Components.Schemas.FrozenExport {
        guard let row = try await sql.raw("SELECT manifest FROM study_export_files WHERE id = \(bind: snapshot.id)").first() else {
            return snapshot.manifest
        }
        let result = try JSONDecoder().decode(Components.Schemas.FrozenExport.self, from: row.decode(column: "manifest", as: Data.self))
        guard UUID(uuidString: result.id) == snapshot.id, UUID(uuidString: result.studyId) == snapshot.studyID,
              result.status == .ready, result.sha256 != nil else { throw ServerError.unexpectedError }
        return result
    }

    func page(offset: Int, limit: Int) async throws -> Components.Schemas.FrozenExportPage {
        guard offset >= 0, (1...100).contains(limit) else { throw ServerError.badRequest("Invalid export page") }
        guard let row = try await sql.raw("SELECT members FROM study_export_files WHERE id = \(bind: snapshot.id)").first() else {
            throw ServerError.conflict("Export requires execution")
        }
        let members = try JSONDecoder().decode([Components.Schemas.FrozenExportMember].self, from: row.decode(column: "members", as: Data.self))
        guard offset <= members.count else { throw ServerError.badRequest("Invalid export offset") }
        let end = min(offset + limit, members.count)
        return .init(exportId: snapshot.id.uuidString, members: Array(members[offset..<end]), nextOffset: end < members.count ? end : nil)
    }

    func download() async throws -> Data {
        let summary = try await manifest()
        guard summary.status == .ready,
              let row = try await sql.raw("SELECT ndjson FROM study_export_files WHERE id = \(bind: snapshot.id)").first() else {
            throw ServerError.conflict("Export requires execution")
        }
        let bytes = try row.decode(column: "ndjson", as: Data.self)
        guard summary.byteCount == bytes.count, summary.sha256 == FHIRValidationClient.digest(bytes) else {
            throw ServerError.internalServerError("Stored export checksum mismatch")
        }
        return bytes
    }
}
