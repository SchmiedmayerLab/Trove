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
    enum Namespace: String { case repository, entryNode = "entry-node" }

    struct ConversionInputs: Sendable {
        let source: Components.Schemas.ParticipantSource
        let privacy: PseudonymousIdentityScope
        let application: HealthKitApplication
        let host: HealthKitHostDevice
        let instant: Date

        var repositoryScope: BusinessIdentifier {
            get throws { try BusinessIdentifier(system: namespace(.repository, eventSystem: source.eventIdentifierSystem), value: "healthkit") }
        }

        func eventIdentifier(sequence: Int64) throws -> ExchangeEventIdentifier {
            guard sequence > 0, let producer = UUID(uuidString: source.producerInstance) else { throw AcquisitionError.unsupportedDelta }
            return try ExchangeEventIdentifier(
                system: IdentifierSystem(source.eventIdentifierSystem), producerInstance: producer, sequence: UInt64(sequence)
            )
        }
    }

    /// Derive complete namespaces, not URL paths: the server may issue a UUID URN.
    static func namespace(_ role: Namespace, eventSystem: String) throws -> IdentifierSystem {
        let identifier = try BusinessIdentifier(system: eventSystem, value: "trove-healthkit-namespace-v1:\(role.rawValue)")
        return try IdentifierSystem(ExchangeIdentity.fullURL(for: identifier))
    }

    static func payload(
        _ sample: HKQuantitySample, sequence: Int64, snapshot: ParticipantCollectionSnapshot, context: ConversionInputs
    ) throws -> EventDeliveryJournal.Payload? {
        guard sample.quantityType == HKQuantityType(.heartRate) else { throw AcquisitionError.unsupportedDelta }
        let nativeConsents = try Set(snapshot.consentIDs(forHeartRateAt: sample.startDate))
        guard !nativeConsents.isEmpty else {
            return nil
        }
        let participant = try BusinessIdentifier(
            system: context.source.participantIdentifier.system, value: context.source.participantIdentifier.value
        )
        let event = try context.eventIdentifier(sequence: sequence)
        let conversion = try HealthKitConverter().convert(sample, context: .init(
            subject: .init(identifier: participant.fhirIdentifier, type: .init(stringLiteral: "Patient")),
            subjectIdentity: participant,
            converter: context.application,
            converterHost: context.host,
            eventIdentifier: event,
            entryNodeIdentifierSystem: namespace(.entryNode, eventSystem: context.source.eventIdentifierSystem),
            identityScope: context.privacy,
            repositoryScope: context.repositoryScope,
            conversionInstant: context.instant
        ))
        guard case .dateTime(let effective)? = conversion.observation.effective, let date = effective.value else {
            throw AcquisitionError.unsupportedDelta
        }
        // Both source time and Grove's canonical wire time must be inside the selected consent.
        // Millisecond rounding must not turn a pre-consent sample into authorized collection.
        let consents = try snapshot.consentIDs(forHeartRateAt: date.asNSDate()).filter { nativeConsents.contains($0) }
        guard !consents.isEmpty else {
            return nil
        }
        let output = try ExchangeIdentity.fullURL(for: conversion.graphIdentifiers.primaryOutput)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try .init(bytes: encoder.encode(conversion.bundle), targets: consents.map { .init(consentID: $0, outputFullURLs: [output]) })
    }

    /// HealthKit deletions contain only the native UUID. Re-derive the converter's exact logical
    /// identities with the retained key, without a second sample store or copies of clinical data.
    static func retraction(_ id: UUID, sequence: Int64, context: ConversionInputs) throws -> EventDeliveryJournal.Payload {
        let type = HKQuantityType(.heartRate).identifier
        guard let output = HealthKitCatalog.primaryObservationOutput(forSourceTypeIdentifier: type) else {
            throw AcquisitionError.unsupportedDelta
        }
        let record = try context.privacy.sourceRecord(
            adapterID: "healthkit", sourceType: type, repositoryScope: context.repositoryScope, nativeRecordID: id.uuidString.lowercased()
        )
        let target = try context.privacy.sourceOutput(
            adapterID: "healthkit",
            sourceType: type,
            repositoryScope: context.repositoryScope,
            nativeRecordID: id.uuidString.lowercased(),
            outputRole: output.role,
            outputDiscriminator: output.discriminator
        )
        let event = try context.eventIdentifier(sequence: sequence)
        let assembler = try context.privacy.deviceSnapshot(
            eventIdentifier: event, deviceRole: .application, sourceDeviceToken: context.application.bundleIdentifier
        )
        let graph = try RetractionEventBuilder.build(
            targets: [.init(identifier: target, resourceType: .observation, role: .primaryOutput)],
            context: .init(
                eventIdentifier: event,
                entryNodeIdentifierSystem: namespace(.entryNode, eventSystem: context.source.eventIdentifierSystem),
                producer: .init(identifier: assembler.fhirIdentifier, type: "Device"),
                sourceRecord: record,
                // The deletion occurred no later than this observation; its exact time is unavailable.
                occurred: .period(.init(end: .init(try .init(date: context.instant)))),
                recordedAt: context.instant
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try .init(bytes: encoder.encode(graph.bundle), targets: [])
    }
}

#endif
