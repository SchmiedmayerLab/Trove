//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveFHIRContract
import GroveSensorKitFHIR
import ModelsR4


/// Complete source custody is distinct from each study's independent access to its outputs.
enum FHIRSensorKitCompanions {
    /// A hybrid records its measurement interval on its reciprocal summary, not twice.
    static func relatedPeriod(
        _ document: DocumentReference, fullURL: String, resources: [String: ResourceProxy]
    ) throws -> Period? {
        guard try FHIRSourceTypeEvidence.extract(document.extension ?? [])?.repository == .sensorKit,
              document.context?.period == nil else { return nil }
        guard let references = document.context?.related, references.count == 1,
              let reference = references.first,
              let address = try FHIRClinicalDerivations.outputTarget(reference, resources: resources),
              case .observation(let summary)? = resources[address],
              let origins = summary.derivedFrom, origins.count == 1, let origin = origins.first,
              try FHIRClinicalDerivations.outputTarget(origin, resources: resources) == fullURL,
              case .period(let period)? = summary.effective,
              try sourceRecord(document.identifier ?? []) == sourceRecord(summary.identifier ?? []) else {
            throw FHIRValidationClient.invalid
        }
        return period
    }

    private static func sourceRecord(_ identifiers: [Identifier]) throws -> BusinessIdentifier {
        let roles = try identifiers.map { try RoledIdentifier($0) }.filter { $0.role == .sourceRecord }
        guard roles.count == 1, let identity = roles.first?.identifier else { throw FHIRValidationClient.invalid }
        return identity
    }

    static func validate(_ outputs: [ValidatedExchangeEvent.Output]) throws {
        guard outputs.contains(where: { $0.sourceRepositoryKind == .sensorKit }) else {
            guard !outputs.contains(where: { $0.value == .recording }) || outputs.count == 1 else { throw FHIRValidationClient.invalid }
            return
        }
        guard let token = outputs.first?.sourceTypeIdentifier,
              outputs.allSatisfy({ $0.sourceRepositoryKind == .sensorKit && $0.sourceTypeIdentifier == token }),
              Set(outputs.map(\.sourceRecordIdentifier)).count == 1,
              let definition = SensorKitCatalog.current.entry(sourceToken: token)?.implementedOutput else { throw FHIRValidationClient.invalid }
        let recordings = outputs.filter { $0.value == .recording }
        let observations = outputs.filter { $0.value != .recording }
        guard recordings.count <= 1, observations.count <= 1,
              recordings.allSatisfy({ recording in
                  recording.profile == SensorKitContract.recordingDocumentProfile
                      && definition.recordingFormats.contains(where: { $0.rawValue == recording.code })
              }),
              observations.allSatisfy({ $0.profile == definition.observation?.primaryProfile }) else { throw FHIRValidationClient.invalid }
        if definition.observation?.requiresRecording == true {
            guard recordings.count == 1, observations.count == 1 else { throw FHIRValidationClient.invalid }
        }
    }

    static func validateDependencies(_ event: ValidatedExchangeEvent) throws {
        for output in event.outputs where output.sourceRepositoryKind == .sensorKit && output.value != .recording {
            guard let token = output.sourceTypeIdentifier,
                  let definition = SensorKitCatalog.current.entry(sourceToken: token)?.implementedOutput else { throw FHIRValidationClient.invalid }
            guard definition.observation?.requiresRecording == true else { continue }
            let references = event.outputDependencies.filter { $0.outputFullURL == output.fullURL && $0.relation == .derivedFrom }
            guard references.count == 1, let target = references.first?.targetFullURL,
                  event.outputs.contains(where: { $0.fullURL == target && $0.value == .recording }) else { throw FHIRValidationClient.invalid }
        }
    }
}
