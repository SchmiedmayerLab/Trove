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


final class ClinicalEventService: Module, Sendable {
    let database: any Database
    let validator: FHIRValidationClient

    init(database: any Database, validator: FHIRValidationClient) {
        self.database = database
        self.validator = validator
    }

    func accept(body: HTTPBody, sourceID: UUID, targets: [ClinicalEventTarget]) async throws -> ClinicalEventReceipt {
        _ = try AuthContext.checkIsParticipant()
        _ = try ClinicalEventIntent(targets: targets)
        // Refuse unknown, foreign, or revoked sources before spending validator resources.
        // The store repeats this check under the transaction lock before admitting anything.
        let source = try await SourceBindingService(database: database).find(id: sourceID)
        guard source.revokedAt == nil else { throw ServerError.conflict("Source binding is not active") }
        let bytes: Data
        do {
            bytes = try await BoundedRequestBody.collect(body, upTo: FHIRValidationClient.maximumBytes)
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
        let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: identity)
        return try await ClinicalEventStore(database: database).accept(event, sourceID: sourceID, targets: targets)
    }
}
