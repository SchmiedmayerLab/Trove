//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveSensorKitFHIR
import ModelsR4
import TroveAPIClient


extension SensorKitAcquisition {
    struct ConsentSelection {
        let consents: [CollectionObservationProfile: Set<UUID>]
        let sourceToken: String
        let recordings: [Recording]
        var rowScoped = false
    }

    static func exporter(
        source: Components.Schemas.ParticipantSource,
        privacy: OpaqueIdentityScope,
        facts: SensorKitBatchSnapshot
    ) throws -> SensorKitFHIRExporter {
        let producer = try ExchangeProducer(
            identityScope: privacy,
            subject: .logical(BusinessIdentifier(
                system: IdentifierSystem(source.participantIdentifier.system), value: source.participantIdentifier.value
            )),
            application: facts.application,
            host: facts.host
        )
        var options = SensorKitFHIRExporter.Options()
        options.maximumConcurrency = 1
        return try SensorKitFHIRExporter(
            producer: producer,
            repositoryScope: BusinessIdentifier(
                system: IdentifierSystem(source.repositoryScope.system), value: source.repositoryScope.value
            ),
            visitLocationIdentifierSystem: IdentifierSystem(source.identifierRoot + "/NamingSystem/sensorkit-visit-location"),
            options: options
        )
    }

    static func payloads(
        _ inputs: [Input],
        exporter: SensorKitFHIRExporter,
        facts: SensorKitBatchSnapshot,
        snapshot: ParticipantCollectionSnapshot,
        limits: EventDeliveryJournal.Limits
    ) async throws -> PreparedPage {
        var selected: [SensorKitRecord] = []
        var permissions: [UUID: ConsentSelection] = [:]
        for input in inputs {
            if let permission = try selection(for: input, snapshot: snapshot) {
                selected.append(input.record)
                permissions[input.sourceID.uuid] = permission
            }
        }
        var preparedByteCount = 0
        var payloads: [EventDeliveryJournal.Payload] = []
        var declarations: [[Components.Schemas.RecordingTransferDeclaration]] = []
        try await exporter.export(
            selected,
            sourceTimeZone: facts.sourceTimeZone,
            recordingDevice: facts.recordingDevice,
            sourceDevices: facts.sourceDevices,
            sourceDevicesSuppliedEverySample: facts.sourceDevicesSuppliedEverySample,
            at: facts.conversionInstant
        ) { result in
            guard case .record(let record) = result.outcome, let native = permissions[result.source.uuid] else {
                throw AcquisitionError.conversionRefused
            }
            if let prepared = try payload(record, snapshot: snapshot, native: native) {
                let size = prepared.payload.bytes.count
                guard size <= limits.maximumPayloadBytes, size <= limits.maximumBytes - preparedByteCount else {
                    throw EventDeliveryJournal.JournalError.capacityExceeded
                }
                preparedByteCount += size
                payloads.append(prepared.payload)
                declarations.append(prepared.declarations)
            }
        }
        return PreparedPage(payloads: payloads, declarations: declarations)
    }

    private static func selection(for input: Input, snapshot: ParticipantCollectionSnapshot) throws -> ConsentSelection? {
        let profiles = [input.profile] + input.companionProfiles
        if let authorization = input.rowAuthorization {
            let rowConsents = authorization.consents
            guard Set(rowConsents.keys) == Set(profiles), rowConsents.values.allSatisfy({ !$0.isEmpty }) else {
                throw AcquisitionError.invalidBatch
            }
            return ConsentSelection(consents: rowConsents, sourceToken: input.sourceToken, recordings: input.recordings, rowScoped: true)
        }
        guard Set(profiles).count == profiles.count else { throw AcquisitionError.invalidBatch }
        var permissions: [CollectionObservationProfile: Set<UUID>] = [:]
        for profile in profiles {
            let consents = try snapshot.consentIDs(
                profile: profile, start: input.start, end: input.end, sourceTypeIdentifier: input.sourceToken
            )
            // A complete producer graph needs authority for every output. Studies keep separate output grants.
            guard !consents.isEmpty else {
                return nil
            }
            permissions[profile] = Set(consents)
        }
        return ConsentSelection(consents: permissions, sourceToken: input.sourceToken, recordings: input.recordings)
    }
}
