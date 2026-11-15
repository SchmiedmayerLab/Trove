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
import ModelsR4
import TroveAPIClient


extension HealthKitAcquisition {
    struct PreparedPage {
        let payloads: [EventDeliveryJournal.Payload]
        let recordingDeclarations: [[Components.Schemas.RecordingTransferDeclaration]]
    }

    struct ConversionTiming {
        let batchInstant: Date
        let records: [UUID: Date]
        let deletions: [UUID: Date]
    }

    /// The application's build identifies its converter code. Bump the policy marker when export
    /// options change; application and host facts also affect the conversion Provenance.
    static func conversionConfiguration(application: ApplicationDevice, host: HostDevice) throws -> Data {
        try JSONEncoder().encode([
            "trove-healthkit-record-v4-source-document-dates", application.name, application.bundleIdentifier,
            application.version, application.build, host.operatingSystemName, host.operatingSystemVersion,
            host.operatingSystemBuild, host.productType, host.model, host.name, host.manufacturer
        ])
    }

    /// Source revision is assigned by the HealthKit store and can differ from an unsaved object's
    /// revision. Include it so changed writer facts receive a new conversion time.
    static func recordConfiguration(for sample: HKSample, converter: Data) throws -> Data {
        let revision = sample.sourceRevision
        let writer = try JSONEncoder().encode([
            revision.source.name, revision.source.bundleIdentifier, revision.version, revision.productType,
            String(revision.operatingSystemVersion.majorVersion), String(revision.operatingSystemVersion.minorVersion),
            String(revision.operatingSystemVersion.patchVersion)
        ])
        return try JSONEncoder().encode([converter, writer])
    }

    static func exporter(
        source: Components.Schemas.ParticipantSource,
        privacy: OpaqueIdentityScope,
        application: ApplicationDevice,
        host: HostDevice,
        stream: HealthKitQueryDefinition.Stream = .heartRate
    ) throws -> HealthKitFHIRExporter {
        let participant = try BusinessIdentifier(
            system: IdentifierSystem(source.participantIdentifier.system), value: source.participantIdentifier.value
        )
        let producer = try ExchangeProducer(
            identityScope: privacy, subject: .logical(participant), application: application, host: host
        )
        var options = HealthKitFHIRExporter.Options()
        options.route = stream == .workoutRoute ? .authorized : .omit
        options.nativeIdentifier = .authorized(system: try source.nativeRecordIdentifierSystem())
        // Trove preserves all source metadata, identifying and custom keys included; no study narrows it.
        options.metadata = .all
        return try HealthKitFHIRExporter(
            producer: producer,
            repositoryScope: BusinessIdentifier(
                system: IdentifierSystem(source.repositoryScope.system), value: source.repositoryScope.value
            ),
            options: options
        )
    }

    static func prepare(
        _ delta: Delta,
        exporter: HealthKitFHIRExporter,
        snapshot: ParticipantCollectionSnapshot,
        timing: ConversionTiming,
        profile: CollectionObservationProfile = .heartRate
    ) async throws -> PreparedPage {
        try await prepare(delta, exporter: exporter, snapshot: snapshot, timing: timing, stream: .init(profile))
    }

    static func prepare(
        _ delta: Delta,
        exporter: HealthKitFHIRExporter,
        snapshot: ParticipantCollectionSnapshot,
        timing: ConversionTiming,
        stream: HealthKitQueryDefinition.Stream
    ) async throws -> PreparedPage {
        guard Set(delta.added.map(\.uuid)).count == delta.added.count else { throw AcquisitionError.unsupportedDelta }
        if stream.profile == .food {
            return try await prepareFood(delta, exporter: exporter, snapshot: snapshot, timing: timing, stream: stream)
        }
        var nativeConsents: [UUID: Set<UUID>] = [:]
        let samples = try delta.added.filter { sample in
            let consents = try Set(consentIDs(for: sample, stream: stream, snapshot: snapshot))
            nativeConsents[sample.uuid] = consents
            return !consents.isEmpty
        }
        var payloads: [EventDeliveryJournal.Payload] = []
        var declarations: [[Components.Schemas.RecordingTransferDeclaration]] = []
        let groups = try Dictionary(grouping: samples) { sample in
            guard let instant = timing.records[sample.uuid] else { throw AcquisitionError.unsupportedDelta }
            return instant
        }
        for time in groups.keys.sorted() {
            var records: [HealthKitFHIRExporter.Record] = []
            var recordings: [UUID: HealthKitRecordingFile] = [:]
            for sample in groups[time] ?? [] {
                let record = try await inputRecord(sample, stream: stream, delta: delta)
                if case .fileRecording(let recording) = record { recordings[sample.uuid] = recording }
                records.append(record)
            }
            try await exporter.export(records: records, at: time) { result in
                guard case .record(let record) = result.outcome,
                      let consents = nativeConsents[result.source.uuid] else { throw AcquisitionError.unsupportedDelta }
                if let prepared = try Self.payload(
                    for: record, stream: stream, snapshot: snapshot, nativeConsents: consents, recording: recordings[result.source.uuid]
                ) {
                    payloads.append(prepared.payload)
                    declarations.append(prepared.declarations)
                }
            }
        }
        let deletions = try retractions(delta, timing: timing, stream: stream)
        try await exporter.retract(deletions, at: timing.batchInstant) { result in
            guard case .record(let record) = result.outcome else { throw AcquisitionError.unsupportedDelta }
            payloads.append(.init(bytes: record.json, targets: []))
            declarations.append([])
        }
        return PreparedPage(payloads: payloads, recordingDeclarations: declarations)
    }

    private static func inputRecord(
        _ sample: HKSample, stream: HealthKitQueryDefinition.Stream, delta: Delta
    ) async throws -> HealthKitFHIRExporter.Record {
        if stream.timeBasis != .measurementTime {
            return .fileRecording(try await delta.readDocument(sample))
        }
        if stream.profile == .healthKitRecording {
            guard let series = sample as? HKHeartbeatSeriesSample else { throw AcquisitionError.unsupportedDelta }
            return .fileRecording(try await delta.readHeartbeatSeries(series))
        }
        guard stream == .workoutRoute else {
            return .sample(sample)
        }
        guard let route = sample as? HKWorkoutRoute else { throw AcquisitionError.unsupportedDelta }
        // Read companion locations only after the native interval has an accepted route consent.
        return .fileRecording(try await delta.readRoute(route))
    }

    static func retractions(
        _ delta: Delta, timing: ConversionTiming, stream: HealthKitQueryDefinition.Stream
    ) throws -> [HealthKitFHIRExporter.Deletion] {
        guard let type = HealthKitSourceType(rawValue: try sampleType(for: stream).identifier) else { throw AcquisitionError.unsupportedDelta }
        return try delta.deletedIDs.map { id in
            guard let detectedAt = timing.deletions[id] else { throw AcquisitionError.unsupportedDelta }
            return .init(uuid: id, sourceType: type, deletedAfter: nil, detectedAt: detectedAt)
        }
    }

    static func consentIDs(
        for sample: HKSample, profile: CollectionObservationProfile, snapshot: ParticipantCollectionSnapshot
    ) throws -> [UUID] {
        try consentIDs(for: sample, stream: .init(profile), snapshot: snapshot)
    }

    static func consentIDs(
        for sample: HKSample, stream: HealthKitQueryDefinition.Stream, snapshot: ParticipantCollectionSnapshot
    ) throws -> [UUID] {
        guard sample.sampleType == (try sampleType(for: stream)) else { throw AcquisitionError.unsupportedDelta }
        return try snapshot.consentIDs(
            profile: stream.profile,
            start: sample.startDate,
            end: stream.profile.permitsEffectiveTime(hasEnd: true) ? sample.endDate : nil,
            requiresWorkoutRoute: stream == .workoutRoute,
            sourceTypeIdentifier: stream.sourceTypeIdentifier,
            timeBasis: stream.timeBasis
        )
    }

    private static func primaryObservation(
        _ observations: [(BundleEntry, Observation)], profile: CollectionObservationProfile
    ) throws -> Observation {
        let primary = observations.filter { $0.1.meta?.profile?.contains(where: { $0.value?.url.absoluteString == profile.rawValue }) == true }
        guard primary.count == 1, let (_, observation) = primary.first else { throw AcquisitionError.unsupportedDelta }
        let fullURLs = observations.compactMap { $0.0.fullUrl?.value?.url.absoluteString }
        guard fullURLs.count == observations.count, Set(fullURLs).count == fullURLs.count else { throw AcquisitionError.unsupportedDelta }
        if profile == .workout {
            let segments = observations.filter { $0.1.meta?.profile?.contains(Profile.groveMobileWorkoutSegment) == true }
            let members = observation.hasMember?.compactMap { $0.reference?.value?.string } ?? []
            guard segments.count + 1 == observations.count, members.count == segments.count,
                  Set(members) == Set(segments.compactMap { $0.0.fullUrl?.value?.url.absoluteString }) else {
                throw AcquisitionError.unsupportedDelta
            }
        } else {
            guard observations.count == 1 else { throw AcquisitionError.unsupportedDelta }
        }
        return observation
    }

    static func payload(
        for record: ExchangeRecord,
        stream: HealthKitQueryDefinition.Stream,
        snapshot: ParticipantCollectionSnapshot,
        nativeConsents: Set<UUID>,
        recording: HealthKitRecordingFile?
    ) throws -> (payload: EventDeliveryJournal.Payload, declarations: [Components.Schemas.RecordingTransferDeclaration])? {
        if stream == .workoutRoute || stream.profile == .healthKitRecording || stream.profile == .clinicalDocument {
            guard let recording else { throw AcquisitionError.unsupportedDelta }
            return try recordingPayload(for: record, recording: recording, stream: stream, snapshot: snapshot, nativeConsents: nativeConsents).map {
                ($0.payload, [$0.declaration])
            }
        }
        guard record.json.count <= EventSubmissionLimits.maximumEventBytes else { throw EventDeliveryJournal.JournalError.capacityExceeded }
        let profile = stream.profile
        let graph = try ExchangeGraph(validating: record.json, kind: .active)
        let observations = (graph.bundle.entry ?? []).compactMap { entry in
            if case .observation(let observation)? = entry.resource { (entry, observation) } else { nil }
        }
        let observation = try primaryObservation(observations, profile: profile)
        let fullURLs = observations.compactMap { $0.0.fullUrl?.value?.url.absoluteString }
        // Native and canonical wire timestamps must both be covered. Rounding must
        // never move a sample across an accepted measurement boundary.
        let wireConsents: [UUID]
        switch observation.effective {
        case .dateTime(let effective):
            guard let date = effective.value else { throw AcquisitionError.unsupportedDelta }
            wireConsents = try snapshot.consentIDs(
                profile: profile, start: date.asNSDate(), end: nil, sourceTypeIdentifier: stream.sourceTypeIdentifier
            )
        case .period(let period):
            guard let start = period.start?.value, let end = period.end?.value else { throw AcquisitionError.unsupportedDelta }
            wireConsents = try snapshot.consentIDs(
                profile: profile, start: start.asNSDate(), end: end.asNSDate(), sourceTypeIdentifier: stream.sourceTypeIdentifier
            )
        default:
            throw AcquisitionError.unsupportedDelta
        }
        let consents = wireConsents.filter { nativeConsents.contains($0) }
        guard !consents.isEmpty else {
            return nil
        }
        return (.init(bytes: record.json, targets: consents.map { .init(consentID: $0, outputFullURLs: fullURLs) }), [])
    }
}


extension HealthKitAcquisition {
    func preparePage(
        _ delta: Delta,
        checkpoint: EventDeliveryJournal.Checkpoint,
        snapshot: ParticipantCollectionSnapshot,
        exporter: HealthKitFHIRExporter,
        configuration: Data
    ) async throws -> PreparedPage {
        let definition = try HealthKitQueryDefinition(bytes: checkpoint.queryDefinition)
        let selected = try Self.partition(delta, definition: definition)
        let eligible = try selected.added.filter {
            try !Self.consentIDs(for: $0, stream: definition.stream, snapshot: snapshot).isEmpty
        }
        let instant = try await journal.conversionInstant(from: checkpoint)
        let detections = try await journal.deletionDetections(for: delta.deletedIDs, from: checkpoint, at: instant)
        var records: [UUID: Date] = [:]
        let conversionSamples = try Self.conversionSamples(eligible, stream: definition.stream, snapshot: snapshot)
        let groups = try Dictionary(grouping: conversionSamples) { try Self.recordConfiguration(for: $0, converter: configuration) }
        for (context, samples) in groups {
            let saved = try await journal.healthKitConversionInstants(
                for: samples.map(\.uuid), configuration: context, from: checkpoint, at: instant
            )
            records.merge(saved) { first, _ in first }
        }
        return try await Self.prepare(
            selected,
            exporter: exporter,
            snapshot: snapshot,
            timing: ConversionTiming(batchInstant: instant, records: records, deletions: detections),
            stream: definition.stream
        )
    }
}

#endif
