//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if canImport(HealthKit)

import Foundation
import GroveFHIRContract
import GroveHealthKitFHIR
import HealthKit
import TroveAPIClient


extension HeartRateAcquisition {
    struct PreparedPage {
        let payloads: [EventDeliveryJournal.Payload]
        let receipts: [ExchangeProducer.Receipt]
    }

    static func exporter(
        source: Components.Schemas.ParticipantSource,
        privacy: OpaqueIdentityScope,
        application: ApplicationDevice,
        host: HostDevice,
        storage: some ExchangeProducer.Storage
    ) throws -> HealthKitFHIRExporter {
        let participant = try BusinessIdentifier(
            system: IdentifierSystem(source.participantIdentifier.system), value: source.participantIdentifier.value
        )
        let producer = try ExchangeProducer(
            identityScope: privacy, subject: .logical(participant), application: application, host: host, storage: storage
        )
        return try HealthKitFHIRExporter(
            producer: producer,
            repositoryScope: BusinessIdentifier(
                system: IdentifierSystem(source.identifierRoot + "/repository"), value: "healthkit"
            )
        )
    }

    static func prepare(
        _ delta: Delta,
        exporter: HealthKitFHIRExporter,
        snapshot: ParticipantCollectionSnapshot,
        detections: [UUID: Date]
    ) async throws -> PreparedPage {
        guard Set(delta.added.map(\.uuid)).count == delta.added.count else { throw AcquisitionError.unsupportedDelta }
        var nativeConsents: [UUID: Set<UUID>] = [:]
        let samples = try delta.added.filter { sample in
            guard sample.quantityType == HKQuantityType(.heartRate) else { throw AcquisitionError.unsupportedDelta }
            let consents = try Set(snapshot.consentIDs(forHeartRateAt: sample.startDate))
            nativeConsents[sample.uuid] = consents
            return !consents.isEmpty
        }
        var payloads: [EventDeliveryJournal.Payload] = []
        let exported = try await exporter.export(samples) { result in
            guard case .graph(let graph) = result.outcome else { throw AcquisitionError.unsupportedDelta }
            let observations = (graph.bundle.entry ?? []).compactMap { entry in
                if case .observation(let observation)? = entry.resource { (entry, observation) } else { nil }
            }
            guard observations.count == 1, let (entry, observation) = observations.first,
                  let fullURL = entry.fullUrl?.value?.url.absoluteString,
                  case .dateTime(let effective)? = observation.effective, let date = effective.value,
                  let original = nativeConsents[result.source.uuid] else { throw AcquisitionError.unsupportedDelta }
            // Native and canonical wire timestamps must both be covered. Rounding must
            // never turn a pre-consent sample into authorized collection.
            let consents = try snapshot.consentIDs(forHeartRateAt: date.asNSDate()).filter { original.contains($0) }
            guard !consents.isEmpty else {
                return
            }
            payloads.append(.init(bytes: graph.json, targets: consents.map { .init(consentID: $0, outputFullURLs: [fullURL]) }))
        }
        let deletions = try delta.deletedIDs.map { id in
            guard let detectedAt = detections[id] else { throw AcquisitionError.unsupportedDelta }
            return HealthKitFHIRExporter.Deletion(uuid: id, sourceType: .heartRate, deletedAfter: nil, detectedAt: detectedAt)
        }
        let retracted = try await exporter.retract(deletions) { result in
            guard case .graph(let graph) = result.outcome else { throw AcquisitionError.unsupportedDelta }
            payloads.append(.init(bytes: graph.json, targets: []))
        }
        return PreparedPage(payloads: payloads, receipts: [exported, retracted])
    }
}

#endif
