// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import GroveFHIRContract
import GroveSensorKitFHIR


/// Implemented native collection outputs. Guide inventory alone does not authorize acquisition.
/// A source's complete custody graph and each study's output selection are independent requirements.
public enum SensorKitCollectionCapabilities {
    public struct Output: Sendable {
        public let profile: String
        public let isRecording: Bool
        public let effective: SensorKitOutputDefinition.Effective
        /// All output profiles required to retain the producer's complete graph, without granting them to a study.
        public let requiredCompanionProfiles: [String]
    }

    /// Only acquisition families with corresponding closed receiver contracts belong here.
    public static let sources: [SensorKitOutputDefinition] = SensorKitCatalog.current.entries.compactMap { entry in
        switch entry.structuredContract {
        case .onWrist, .visit, .messagesUsage, .phoneUsage, .sleepSession, .accelerometer, .electrocardiogram, .deviceUsage, .wristTemperature, .ppg:
            return entry.implementedOutput
        default:
            guard entry.structuredContract == nil, let format = entry.soleRawFormat,
                  rawFormats.contains(format),
                  SensorKitCatalog.current.entries.filter({ $0.soleRawFormat == format }).count == 1 else {
                return nil
            }
            return entry.implementedOutput
        }
    }

    private static let rawFormats: Set<RegisteredRecordingFormat> = [
        .ambientLightSamples, .ambientPressureSamples, .heartRateSamples,
        .pedometerSamples, .deviceMotionSamples, .headphoneSettingsSamples
    ]

    /// Exact scopes for one sensor. An original recording is a separate output even when required for custody.
    public static func outputs(for sourceTypeIdentifier: String) -> [Output] {
        guard let source = sources.first(where: { $0.sourceToken == sourceTypeIdentifier }) else {
            return []
        }
        var outputs: [Output] = []
        if let observation = source.observation, let profile = observation.primaryProfile {
            outputs.append(Output(
                profile: profile,
                isRecording: false,
                effective: observation.effective,
                requiredCompanionProfiles: source.requiredCompanionProfiles
            ))
        }
        if source.observation == nil || source.observation?.requiresRecording == true {
            guard source.recordingProfiles.contains(SensorKitContract.recordingDocumentProfile), !source.recordingFormats.isEmpty else {
                return []
            }
            outputs.append(Output(
                profile: SensorKitContract.recordingDocumentProfile,
                isRecording: true,
                effective: .period,
                requiredCompanionProfiles: source.observation?.primaryProfile.map { [$0] } ?? []
            ))
        }
        return outputs
    }

    /// The same raw profile can belong to many sensors; source selection is always explicit.
    public static func sources(for profile: String) -> [SensorKitOutputDefinition] {
        sources.filter { source in outputs(for: source.sourceToken).contains { $0.profile == profile } }
    }
}
