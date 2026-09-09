//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import OpenAPIRuntime
import TroveAPIServer


extension Controller {
    func postParticipantSourcesSourceIdEvents(
        _ input: Operations.PostParticipantSourcesSourceIdEvents.Input
    ) async throws -> Operations.PostParticipantSourcesSourceIdEvents.Output {
        _ = try AuthContext.checkIsParticipant()
        guard case .json(let body) = input.body else { throw ServerError.invalidRequestBody }
        let receipt = try await clinicalEventService.accept(submission: body, sourceID: input.path.sourceId.requireId())
        return .ok(.init(body: .json(receipt.apiRepresentation)))
    }

    func submitParticipantEventBatch(
        _ input: Operations.SubmitParticipantEventBatch.Input
    ) async throws -> Operations.SubmitParticipantEventBatch.Output {
        _ = try AuthContext.checkIsParticipant()
        guard case .json(let body) = input.body else { throw ServerError.invalidRequestBody }
        let results = try await clinicalEventService.acceptBatch(body.events, sourceID: input.path.sourceId.requireId())
        return .ok(.init(body: .json(results)))
    }

    func lookupParticipantEventReceipt(
        _ input: Operations.LookupParticipantEventReceipt.Input
    ) async throws -> Operations.LookupParticipantEventReceipt.Output {
        _ = try AuthContext.checkIsParticipant()
        guard case .json(let body) = input.body else { throw ServerError.invalidRequestBody }
        let lookup = try ClinicalEventReceiptStore.Lookup(
            system: body.producerEventIdentifier.system,
            value: body.producerEventIdentifier.value,
            digest: body.payloadSHA256,
            targets: body.targets.map { try $0.domainTarget }
        )
        let receipt = try await ClinicalEventReceiptStore(database: clinicalEventService.database)
            .lookup(lookup, sourceID: input.path.sourceId.requireId())
        return .ok(.init(body: .json(receipt.apiRepresentation)))
    }

    func attributeParticipantEvent(
        _ input: Operations.AttributeParticipantEvent.Input
    ) async throws -> Operations.AttributeParticipantEvent.Output {
        _ = try AuthContext.checkIsParticipant()
        guard case .json(let body) = input.body else { throw ServerError.invalidRequestBody }
        let receipt = try await ClinicalAttributionStore(database: clinicalEventService.database).attribute(
            eventID: input.path.eventId.requireId(),
            sourceID: input.path.sourceId.requireId(),
            commandID: body.commandId.requireId(),
            targets: body.targets.map { try $0.domainTarget }
        )
        return .ok(.init(body: .json(.init(
            commandId: receipt.commandID.uuidString.lowercased(),
            eventId: receipt.eventID.uuidString.lowercased(),
            targetIntentSHA256: receipt.targetIntentSHA256,
            acceptedAt: receipt.acceptedAt,
            authorizedOutputCount: receipt.authorizedOutputCount
        ))))
    }
}


extension Components.Schemas.EventTarget {
    var domainTarget: ClinicalEventTarget {
        get throws { .init(consentID: try consentId.requireId(), outputFullURLs: outputFullUrls) }
    }
}


extension ClinicalEventReceipt {
    var apiRepresentation: Components.Schemas.EventReceipt {
        .init(
            eventId: eventID.uuidString.lowercased(),
            sourceId: sourceID.uuidString.lowercased(),
            producerEventIdentifier: .init(system: producerEventIdentifier.system, value: producerEventIdentifier.value),
            payloadSHA256: payloadSHA256,
            targetIntentSHA256: targetIntentSHA256,
            receivedAt: receivedAt,
            nodeCount: nodeCount
        )
    }
}
