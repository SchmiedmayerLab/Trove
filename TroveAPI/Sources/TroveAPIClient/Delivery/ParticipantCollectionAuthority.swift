//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import TroveAPITypes


extension ParticipantCollectionSnapshot {
    private struct Authority: Encodable {
        let enrollmentID: String
        let studyID: String
        let stateVersion: Int64
        let endsAt: Date?
        let windows: [Components.Schemas.ConsentCollectionWindow]
    }

    /// Foreground review is offered only for an exact retained CDA source and source-document-date scope.
    public var permitsDocumentReview: Bool {
        acquisitionStreams.contains { $0.timeBasis == .cdaSourceDocumentPeriod }
    }

    /// SensorKit queries require explicit authority for every output in their producer graph.
    /// Separate accepted consents may provide that authority; each output retains its own eventual targets.
    public var permitsSensorKitAcquisition: Bool {
        SensorKitCollectionCapabilities.sources.contains { permitsSensorKitAcquisition(sourceTypeIdentifier: $0.sourceToken) }
    }

    /// Preflights complete source custody; per-record time bounds and per-output consent targets remain mandatory.
    public func permitsSensorKitAcquisition(sourceTypeIdentifier: String) -> Bool {
        let outputs = SensorKitCollectionCapabilities.outputs(for: sourceTypeIdentifier)
        return !outputs.isEmpty && outputs.allSatisfy { output in
            guard let profile = CollectionObservationProfile(rawValue: output.profile) else {
                return false
            }
            return permitsAcquisition(of: profile, sourceTypeIdentifier: sourceTypeIdentifier)
        }
    }

    /// Replay identity, not authorization: every staged page still needs a current journal checkpoint.
    /// Observation time and display text do not restart a completed historical sweep.
    public func authorityFingerprint() throws -> String {
        let values = plans.map { plan in
            Authority(
                enrollmentID: plan.enrollmentId,
                studyID: plan.studyId,
                stateVersion: plan.stateVersion,
                endsAt: plan.endsAt,
                windows: plan.windows
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let bytes = try encoder.encode(values)
        guard bytes.count <= 4_194_304 else { throw CollectionError.invalidPlan }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Earliest authorized measurement time for one exact native source, including non-HealthKit adapters.
    public func queryStart(for profile: CollectionObservationProfile, sourceTypeIdentifier: String) -> Date? {
        guard profile.permitsNativeSource(sourceTypeIdentifier),
              permitsAcquisition(of: profile, sourceTypeIdentifier: sourceTypeIdentifier) else {
            return nil
        }
        return plans
            .flatMap(\.windows)
            .flatMap(\.requirements)
            .filter { requirement in
            requirement.sourceKind == .participantApp && requirement.profile == profile.rawValue
                && profile.matchesSource(expected: requirement.sourceTypeIdentifier, actual: sourceTypeIdentifier)
                && (requirement.end.map { $0 > requirement.start } ?? true)
            }
            .map(\.start)
            .min()
    }

    /// Conservative batch preflight, never a grant: each output still needs its own `consentIDs` selection.
    /// A batch's closed min/max may include points at its final instant, so equality at a window start remains eligible.
    public func maySelect(
        profile: CollectionObservationProfile, sourceTypeIdentifier: String, effectiveStart: Date, effectiveEnd: Date
    ) throws -> Bool {
        guard effectiveStart.timeIntervalSince1970.isFinite, effectiveEnd.timeIntervalSince1970.isFinite,
              effectiveStart <= effectiveEnd else { throw CollectionError.invalidPlan }
        guard profile.permitsNativeSource(sourceTypeIdentifier),
              permitsAcquisition(of: profile, sourceTypeIdentifier: sourceTypeIdentifier) else {
            return false
        }
        return plans.contains { plan in
            plan.windows.contains { window in
                window.requirements.contains { requirement in
                    requirement.sourceKind == .participantApp && requirement.profile == profile.rawValue
                        && profile.matchesSource(expected: requirement.sourceTypeIdentifier, actual: sourceTypeIdentifier)
                        && effectiveEnd >= requirement.start
                        && (requirement.end.map { $0 > requirement.start && effectiveStart < $0 } ?? true)
                }
            }
        }
    }
}
