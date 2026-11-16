//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

/// Observation profiles supported by Trove collection policy, not a replacement for Grove's catalog.
public enum CollectionObservationProfile: String, CaseIterable, Codable, Sendable {
    case heartRate = "https://grovealliance.org/fhir/mobile/StructureDefinition/grove-mobile-heart-rate"
    case sleepStage = "https://grovealliance.org/fhir/mobile/StructureDefinition/grove-mobile-sleep-stage"

    case workout = "https://grovealliance.org/fhir/mobile/StructureDefinition/grove-mobile-workout"

    public var isInterval: Bool { self != .heartRate }
}
