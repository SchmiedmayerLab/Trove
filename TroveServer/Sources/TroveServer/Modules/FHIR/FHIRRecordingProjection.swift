//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveHealthKit
import GroveProviderFHIR
import GroveSensorKitFHIR
import ModelsR4
import TroveAPITypes


/// Selection facts from a validated recording. Parsing never replaces or resamples its immutable attachment.
enum FHIRRecordingProjection {
    private struct Descriptor {
        let source: FHIRSourceTypeEvidence
        let format: RegisteredRecordingFormat
        let profile: String
    }

    struct Facts {
        let profile: String
        let format: RegisteredRecordingFormat
        let source: FHIRSourceTypeEvidence
        let bounds: ClinicalMeasurementBounds
    }

    static let profile: String = {
        guard let value = Profile.healthkitRecordingDocument.value?.url.absoluteString else {
            preconditionFailure("The generated recording profile must have a canonical URI")
        }
        return value
    }()
    static let formatSystem = Canonicals.root + "/sensor/CodeSystem/grove-recording-format"
    static let routeFormat = RegisteredRecordingFormat.locationTrackSamples.rawValue

    static func project(
        _ document: DocumentReference, external: ClinicalRecordingAttachment? = nil, selectionPeriod: Period? = nil
    ) throws -> Facts {
        let descriptor = try identity(document)
        let basis = CollectionTimeBasis.required(profile: descriptor.profile, sourceTypeIdentifier: descriptor.source.identifier)
        guard basis == .measurementTime || selectionPeriod != nil else { throw FHIRValidationClient.invalid }
        let rows = try sourceBounds(document, format: descriptor.format, external: external)
        let bounds = try measurementBounds(
            document, selectionPeriod: selectionPeriod, rows: rows, requiresPeriod: descriptor.format != .locationTrackSamples
        )
        guard bounds.end != nil else { throw FHIRValidationClient.invalid }
        try external?.validate(document: document, bounds: bounds)
        return .init(profile: descriptor.profile, format: descriptor.format, source: descriptor.source, bounds: bounds)
    }

    static func routeBounds(_ document: DocumentReference, external: ClinicalRecordingAttachment? = nil) throws -> ClinicalMeasurementBounds {
        let facts = try project(document, external: external)
        guard facts.format == .locationTrackSamples else { throw FHIRValidationClient.invalid }
        return facts.bounds
    }

    private static func identity(_ document: DocumentReference) throws -> Descriptor {
        guard let source = try FHIRSourceTypeEvidence.extract(document.extension ?? []),
              document.content.count == 1, let content = document.content.first,
              content.format?.system?.value?.url.absoluteString == formatSystem,
              let rawFormat = content.format?.code?.value?.string,
              let format = RegisteredRecordingFormat(rawValue: rawFormat),
              let mediaType = content.attachment.contentType?.value?.string,
              format.registeredContentTypes.contains(mediaType) else { throw FHIRValidationClient.invalid }
        switch source.repository {
        case .healthKit: return try healthKitDescriptor(document, source: source, format: format)
        case .sensorKit:
            guard let definition = SensorKitCatalog.current.entry(sourceToken: source.identifier)?.implementedOutput,
                  definition.recordingFormats.contains(format),
                  Set((document.meta?.profile ?? []).compactMap { $0.value?.url.absoluteString }) == Set(definition.recordingProfiles),
                  definition.recordingProfiles.contains(SensorKitContract.recordingDocumentProfile) else { throw FHIRValidationClient.invalid }
            return .init(source: source, format: format, profile: SensorKitContract.recordingDocumentProfile)
        case .withings, .oura, .googleHealthAPI:
            return try providerDescriptor(document, source: source, format: format)
        }
    }

    private static func healthKitDescriptor(
        _ document: DocumentReference, source: FHIRSourceTypeEvidence, format: RegisteredRecordingFormat
    ) throws -> Descriptor {
        if let clinical = try clinicalDescriptor(document, source: source, format: format) {
            return clinical
        }
        guard document.meta?.profile?.contains(Profile.healthkitRecordingDocument) == true else { throw FHIRValidationClient.invalid }
        let expected: String = switch format {
        case .locationTrackSamples: SampleType.workoutRoute.hkSampleType.identifier
        case .beatIntervalSeries: SampleType.heartbeatSeries.hkSampleType.identifier
        default: ""
        }
        guard source.identifier == expected else { throw FHIRValidationClient.invalid }
        return .init(source: source, format: format, profile: profile)
    }

    private static func clinicalDescriptor(
        _ document: DocumentReference, source: FHIRSourceTypeEvidence, format: RegisteredRecordingFormat
    ) throws -> Descriptor? {
        let profile: FHIRPrimitive<Canonical>
        switch format {
        case .fhirResource: profile = Profile.healthkitClinicalRecordDocument
        case .clinicalDocument: profile = Profile.healthkitRecordingDocument
        default: return nil
        }
        guard document.meta?.profile?.contains(profile) == true, let canonical = profile.value?.url.absoluteString,
              let definition = FHIRMeasurementCatalog.healthKitSource(identifier: source.identifier), definition.profiles.contains(profile),
              CollectionTimeBasis.required(profile: canonical, sourceTypeIdentifier: source.identifier) != .measurementTime else {
            throw FHIRValidationClient.invalid
        }
        return .init(source: source, format: format, profile: canonical)
    }

    private static func providerDescriptor(
        _ document: DocumentReference, source: FHIRSourceTypeEvidence, format: RegisteredRecordingFormat
    ) throws -> Descriptor {
        guard format == .providerRecording, let provider = ConnectedProvider(rawValue: source.repository.rawValue),
              ProviderCapabilities.sources(for: provider.converter).contains(where: {
                  $0.token == source.identifier && $0.conversionSupport == .nativeRecording
              }), let profile = Profile.groveSensorRecordingDocument.value?.url.absoluteString else { throw FHIRValidationClient.invalid }
        let profiles = [Profile.groveSensorRecordingDocument, Profile.providersRecordingDocument]
        guard Set((document.meta?.profile ?? []).compactMap { $0.value?.url.absoluteString })
            == Set(profiles.compactMap { $0.value?.url.absoluteString }) else { throw FHIRValidationClient.invalid }
        return .init(source: source, format: format, profile: profile)
    }

    private static func sourceBounds(
        _ document: DocumentReference, format: RegisteredRecordingFormat, external: ClinicalRecordingAttachment?
    ) throws -> RecordingRouteBounds {
        if let external {
            try ClinicalRecordingAttachment.validate(document: document, declaration: external.declaration)
            return external.content.bounds
        }
        guard let content = document.content.first, content.attachment.url == nil,
              let bytes = content.attachment.data?.value?.data(),
              !bytes.isEmpty, bytes.count <= FHIRValidationClient.maximumBytes else { throw FHIRValidationClient.invalid }
        if format.csvColumns == nil {
            try format.validatePayload(bytes, maximumByteCount: FHIRValidationClient.maximumBytes)
            return RecordingRouteBounds()
        }
        var reader = try RecordingCSVReader.Stream(format: format)
        var bounds = RecordingRouteBounds()
        try reader.read(bytes) { try bounds.include($0, format: format) }
        try reader.finish()
        return bounds
    }

    private static func measurementBounds(
        _ document: DocumentReference, selectionPeriod: Period?, rows bounds: RecordingRouteBounds, requiresPeriod: Bool
    ) throws -> ClinicalMeasurementBounds {
        // Publication time does not establish the recording's measurement window.
        if let period = selectionPeriod ?? document.context?.period {
            guard let start = period.start?.value, let end = period.end?.value,
                  start.time != nil, start.timeZone != nil, end.time != nil, end.timeZone != nil else {
                throw FHIRValidationClient.invalid
            }
            let lower = try FHIRMeasurementInstant.exact(start), upper = try FHIRMeasurementInstant.exact(end)
            guard lower <= upper,
                  try bounds.first.map({ try RecordedInstant(authorityDate: $0) >= lower }) ?? true,
                  try bounds.last.map({ try RecordedInstant(authorityDate: $0) <= upper }) ?? true else {
                throw FHIRValidationClient.invalid
            }
            return try .init(start: lower, end: upper)
        }
        guard !requiresPeriod, let first = bounds.first, let last = bounds.last else { throw FHIRValidationClient.invalid }
        return try .init(start: first, end: last)
    }
}
