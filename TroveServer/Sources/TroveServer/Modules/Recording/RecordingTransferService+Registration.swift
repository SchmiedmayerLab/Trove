//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import OpenAPIRuntime
import SQLKit
import TroveAPIServer


extension RecordingTransferService {
    func register(
        sourceID: UUID, transferID: UUID, declaration: RecordingTransferDeclaration, installation: SourceInstallationProof
    ) async throws -> Components.Schemas.RecordingTransferRegistration {
        let context = try AuthContext.checkIsParticipant()
        let authorization = Authorization(sourceID: sourceID, installation: installation, context: context)
        guard declaration.content.storedByteCount <= limits.storedBytes, declaration.content.sourceByteCount <= limits.sourceBytes else {
            throw ServerError(status: .contentTooLarge, title: "Recording Too Large", detail: "Recording exceeds the configured transfer budget")
        }
        try await database.transaction { transaction in
            let now = Date()
            let source = try await self.authorize(authorization, declaration: declaration, now: now, on: transaction)
            guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
            let id = try await RecordingTransferStore(sql: sql).declarationID(
                sourceID: sourceID, transferID: transferID, declaration: declaration, now: now
            )
            // Each successful registration, including replay, records the acknowledged immutable declaration.
            try await AuditRepository.recordMutation(.init(
                context: context.auditContext,
                action: .recordingTransferDeclared,
                scope: .participantSource(participantID: source.participantID, sourceBindingID: sourceID),
                target: .init(id: id)
            ), on: transaction)
        }
        return .init(
            sourceId: sourceID.uuidString.lowercased(),
            transferId: transferID.uuidString.lowercased(),
            declarationSHA256: declaration.sha256,
            storedByteCount: Int64(declaration.content.storedByteCount),
            storedSHA256: declaration.content.storedSHA256
        )
    }

    func uploadRegistered(
        _ body: HTTPBody, sourceID: UUID, transferID: UUID, installation: SourceInstallationProof
    ) async throws -> RecordingTransferReceipt {
        _ = try AuthContext.checkIsParticipant()
        let source = try await SourceBindingService(database: database).find(id: sourceID)
        _ = try await installation.validate(source: source, on: database)
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        guard let row = try await sql.raw("""
            SELECT declaration, declaration_sha256 FROM recording_transfers
            WHERE source_id = \(bind: sourceID) AND transfer_id = \(bind: transferID)
            """)
            .first() else { throw ServerError.notFound("Recording declaration not found") }
        let declaration = try RecordingTransferDeclaration(
            restoring: row.decode(column: "declaration", as: String.self), digest: row.decode(column: "declaration_sha256", as: String.self)
        )
        return try await upload(body, sourceID: sourceID, transferID: transferID, declaration: declaration, installation: installation)
    }
}
