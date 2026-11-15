//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import ModelsR4
import TroveAPIClient


extension SensorKitAcquisition {
    struct Output {
        let url: String
        let profile: CollectionObservationProfile
        let start: Date
        let end: Date?
        let document: DocumentReference?
    }

    static func payload(
        _ record: ExchangeRecord, snapshot: ParticipantCollectionSnapshot, native: ConsentSelection
    ) throws -> (payload: EventDeliveryJournal.Payload, declarations: [Components.Schemas.RecordingTransferDeclaration])? {
        let outputs = try outputs(record, profiles: Set(native.consents.keys))
        var granted: [String: [UUID]] = [:]
        var targets: [UUID: [String]] = [:]
        for output in outputs {
            let consents: [UUID]
            if native.rowScoped {
                consents = (native.consents[output.profile] ?? []).sorted { $0.uuidString < $1.uuidString }
            } else {
                let eligible = try snapshot.consentIDs(
                    profile: output.profile, start: output.start, end: output.end, sourceTypeIdentifier: native.sourceToken
                )
                consents = eligible.filter { native.consents[output.profile]?.contains($0) == true }
            }
            guard !consents.isEmpty else {
                return nil
            }
            granted[output.url] = consents
            for consent in consents { targets[consent, default: []].append(output.url) }
        }
        let recordings = try recordings(for: outputs, native: native, grants: granted)
        let payload = EventDeliveryJournal.Payload(
            bytes: record.json,
            targets: targets.keys.sorted { $0.uuidString < $1.uuidString }.map {
                .init(consentID: $0, outputFullURLs: targets[$0, default: []])
            },
            recordings: recordings.map(\.recording)
        )
        return (payload, recordings.map(\.declaration))
    }

    private static func outputs(_ record: ExchangeRecord, profiles: Set<CollectionObservationProfile>) throws -> [Output] {
        let graph = try ExchangeGraph(validating: record.json, kind: .active)
        let urls = Set(record.outputFullURLs)
        let outputs = try (graph.bundle.entry ?? []).compactMap { entry -> Output? in
            guard let url = entry.fullUrl?.value?.url.absoluteString, urls.contains(url) else {
                return nil
            }
            switch entry.resource {
            case .observation(let observation):
                let profile = try matchingProfile(observation.meta, profiles: profiles)
                switch observation.effective {
                case .dateTime(let date):
                    guard let value = date.value else { throw AcquisitionError.conversionRefused }
                    return Output(url: url, profile: profile, start: try value.asNSDate(), end: nil, document: nil)
                case .period(let period):
                    let bounds = try bounds(period)
                    return Output(url: url, profile: profile, start: bounds.start, end: bounds.end, document: nil)
                default: throw AcquisitionError.conversionRefused
                }
            case .documentReference(let document):
                let profile = try matchingProfile(document.meta, profiles: profiles)
                let period = try documentPeriod(document, url: url, graph: graph, outputURLs: urls)
                let bounds = try bounds(period)
                return Output(url: url, profile: profile, start: bounds.start, end: bounds.end, document: document)
            default: throw AcquisitionError.conversionRefused
            }
        }
        guard outputs.count == profiles.count, Set(outputs.map(\.profile)) == profiles, Set(outputs.map(\.url)) == urls else {
            throw AcquisitionError.conversionRefused
        }
        return outputs
    }

    /// Hybrid recordings inherit the exact period of their reciprocal summary in this record.
    /// A study still receives only its separately selected output; this resolves timing, not access.
    private static func documentPeriod(
        _ document: DocumentReference, url: String, graph: ExchangeGraph, outputURLs: Set<String>
    ) throws -> Period {
        if let period = document.context?.period {
            return period
        }
        guard document.context?.related?.count == 1,
              let related = document.context?.related?.first?.reference?.value?.string,
              outputURLs.contains(related),
              let entry = graph.bundle.entry?.first(where: { $0.fullUrl?.value?.url.absoluteString == related }),
              case .observation(let observation) = entry.resource,
              observation.derivedFrom?.count == 1,
              observation.derivedFrom?.first?.reference?.value?.string == url,
              case .period(let period) = observation.effective else { throw AcquisitionError.conversionRefused }
        return period
    }

    private static func matchingProfile(_ meta: Meta?, profiles: Set<CollectionObservationProfile>) throws -> CollectionObservationProfile {
        let matches = profiles.filter { profile in
            meta?.profile?.contains { $0.value?.url.absoluteString == profile.rawValue } == true
        }
        guard matches.count == 1, let profile = matches.first else { throw AcquisitionError.conversionRefused }
        return profile
    }

    private static func bounds(_ period: Period) throws -> (start: Date, end: Date) {
        guard let start = period.start?.value, let end = period.end?.value else { throw AcquisitionError.conversionRefused }
        return (try start.asNSDate(), try end.asNSDate())
    }
}
