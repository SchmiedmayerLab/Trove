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


/// Receiver selection facts from an already validated route recording. The original
/// attachment stays in the immutable record; parsing never replaces or resamples it.
enum FHIRRecordingProjection {
    static let profile = Canonicals.root + "/healthkit/StructureDefinition/healthkit-recording-document"
    static let formatSystem = Canonicals.root + "/sensor/CodeSystem/grove-recording-format"
    static let routeFormat = RegisteredRecordingFormat.locationTrackSamples.rawValue

    static func routeBounds(_ document: DocumentReference, external: ClinicalRecordingAttachment? = nil) throws -> (Date, Date) {
        let bounds = try sourceBounds(document, external: external)
        let result = try measurementBounds(document, rows: bounds)
        try external?.validate(document: document, bounds: result)
        return result
    }

    private static func sourceBounds(_ document: DocumentReference, external: ClinicalRecordingAttachment?) throws -> RecordingRouteBounds {
        let sourceType = (document.extension ?? []).filter {
            $0.url.value?.url.absoluteString == Canonicals.root + "/healthkit/StructureDefinition/healthkit-source-type"
        }
        guard document.meta?.profile?.contains(Profile.healthkitRecordingDocument) == true,
              sourceType.count == 1, case .code(let type)? = sourceType.first?.value,
              type.value?.string == "HKWorkoutRouteTypeIdentifier",
              document.content.count == 1, let content = document.content.first,
              content.format?.system?.value?.url.absoluteString == formatSystem,
              content.format?.code?.value?.string == routeFormat,
              content.attachment.contentType?.value?.string == "text/csv" else { throw FHIRValidationClient.invalid }
        if let external {
            try ClinicalRecordingAttachment.validate(document: document, declaration: external.declaration)
            return external.content.bounds
        }
        guard content.attachment.url == nil, let bytes = content.attachment.data?.value?.data(),
              !bytes.isEmpty, bytes.count <= FHIRValidationClient.maximumBytes else {
            throw FHIRValidationClient.invalid
        }
        var reader = try RecordingCSVReader.Stream(format: .locationTrackSamples)
        var bounds = RecordingRouteBounds()
        try reader.read(bytes) { try bounds.include($0) }
        try reader.finish()
        return bounds
    }

    private static func measurementBounds(_ document: DocumentReference, rows bounds: RecordingRouteBounds) throws -> (Date, Date) {
        // DocumentReference.date is publication time, not the recording's measurement window.
        if let period = document.context?.period {
            guard let start = period.start?.value, let end = period.end?.value,
                  start.time != nil, start.timeZone != nil, end.time != nil, end.timeZone != nil else {
                throw FHIRValidationClient.invalid
            }
            let lower = try start.asNSDate(), upper = try end.asNSDate()
            guard CollectionMeasurementWindow.valid(lower), CollectionMeasurementWindow.valid(upper), lower <= upper,
                  bounds.first.map({ $0 >= lower }) ?? true, bounds.last.map({ $0 <= upper }) ?? true else {
                throw FHIRValidationClient.invalid
            }
            return (lower, upper)
        }
        guard let first = bounds.first, let last = bounds.last else { throw FHIRValidationClient.invalid }
        return (first, last)
    }
}
