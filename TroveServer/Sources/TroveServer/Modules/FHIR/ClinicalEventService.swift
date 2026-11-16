//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import Grove
import OpenAPIRuntime
import TroveAPITypes


final class ClinicalEventService: Module, Sendable {
    let database: any Database
    let validator: FHIRValidationClient
    let limits: EventSubmissionLimits.Configuration
    let recordings: RecordingTransferService

    init(
        database: any Database,
        validator: FHIRValidationClient,
        recordings: RecordingTransferService,
        limits: EventSubmissionLimits.Configuration = .standard
    ) {
        self.database = database
        self.limits = limits
        self.validator = validator
        self.recordings = recordings
    }

    func accept(
        body: HTTPBody,
        sourceID: UUID,
        targets: [ClinicalEventTarget],
        installation: SourceInstallationProof,
        attachments: [Components.Schemas.RecordingAttachmentBinding] = []
    ) async throws -> ClinicalEventReceipt {
        _ = try AuthContext.checkIsParticipant()
        _ = try ClinicalEventIntent(targets: targets)
        // Refuse unknown, foreign, or revoked sources before spending validator resources.
        // The store repeats this check under the transaction lock before admitting anything.
        let source = try await SourceBindingService(database: database).find(id: sourceID)
        _ = try await installation.validate(source: source, on: database)
        let bytes: Data
        do {
            bytes = try await BoundedRequestBody.collect(body, upTo: limits.recordBytes)
        } catch BoundedRequestBody.ReadError.tooLarge {
            throw FHIRValidationClient.tooLarge
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            // Transport diagnostics may contain request data. Only a complete body may be validated.
            throw ServerError(status: .serviceUnavailable, title: "Upload Interrupted", detail: "Retry the unchanged event")
        }
        let identity = try await validator.validate(bytes)
        try Task.checkCancellation()
        let verified = try await recordings.verifyAttachments(attachments, bytes: bytes, source: source, targets: targets, installation: installation)
        let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: identity, recordings: verified)
        return try await ClinicalEventStore(database: database).accept(event, sourceID: sourceID, targets: targets, installation: installation)
    }
}
