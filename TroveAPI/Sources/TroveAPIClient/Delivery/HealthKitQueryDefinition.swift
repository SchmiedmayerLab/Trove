//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPITypes


/// An immutable measurement predicate. Points use start dates; intervals use whole-record overlap.
public struct HealthKitQueryDefinition: Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case live, historical }
    public enum DefinitionError: Error { case invalidDefinition }

    private struct Storage: Codable {
        let adapter: String
        let version: Int
        let stream: Stream
        let kind: Kind
        let start: Date
        let end: Date?
    }

    public let kind: Kind
    public let stream: Stream
    public var profile: CollectionObservationProfile { stream.profile }
    public let start: Date
    public let end: Date?

    public init(profile: CollectionObservationProfile, kind: Kind, start: Date, end: Date? = nil) throws {
        try self.init(stream: Stream(profile), kind: kind, start: start, end: end)
    }

    public init(stream: Stream, kind: Kind, start: Date, end: Date? = nil) throws {
        guard Self.validDate(start), end.map(Self.validDate) ?? true,
              kind == .live ? end == nil : end.map({ $0 > start }) == true else { throw DefinitionError.invalidDefinition }
        self.kind = kind
        self.stream = stream
        self.start = start
        self.end = end
    }

    /// Reject unknown versions, extra fields and noncanonical definitions rather than silently resetting their anchors.
    public init(bytes: Data) throws {
        guard (1...16_384).contains(bytes.count) else { throw DefinitionError.invalidDefinition }
        guard let stored = try? JSONDecoder().decode(Storage.self, from: bytes) else { throw DefinitionError.invalidDefinition }
        guard stored.adapter == "healthkit", stored.version == 6 else { throw DefinitionError.invalidDefinition }
        try self.init(stream: stored.stream, kind: stored.kind, start: stored.start, end: stored.end)
        guard try encoded() == bytes else { throw DefinitionError.invalidDefinition }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Storage(adapter: "healthkit", version: 6, stream: stream, kind: kind, start: start, end: end))
    }

    public func contains(_ sampleStart: Date, ending sampleEnd: Date? = nil) -> Bool {
        guard Self.validDate(sampleStart), sampleEnd.map(Self.validDate) ?? true,
              profile.isInterval == (sampleEnd != nil) else { return false }
        return CollectionMeasurementSelection.includes(sampleStart: sampleStart, sampleEnd: sampleEnd, windowStart: start, windowEnd: end)
    }
}


extension HealthKitQueryDefinition {
    static func validDate(_ date: Date) -> Bool {
        (-62_135_596_800...253_402_300_799).contains(date.timeIntervalSince1970)
    }
}


extension HealthKitQueryDefinition {
    /// Independent anchored streams; route permission remains an option on the workout requirement.
    public enum Stream: String, Codable, CaseIterable, Sendable {
        case heartRate, sleepStage, workout, workoutRoute

        public var profile: CollectionObservationProfile {
            switch self {
            case .heartRate: .heartRate
            case .sleepStage: .sleepStage
            case .workout, .workoutRoute: .workout
            }
        }

        public init(_ profile: CollectionObservationProfile) {
            self = switch profile {
            case .heartRate: .heartRate
            case .sleepStage: .sleepStage
            case .workout: .workout
            }
        }

        func includes(_ requirement: Components.Schemas.CollectionPlanRequirement) -> Bool {
            requirement.profile == profile.rawValue && (self != .workoutRoute || requirement.includeWorkoutRoutes == true)
        }
    }
}
