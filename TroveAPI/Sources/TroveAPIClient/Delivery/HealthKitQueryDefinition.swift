//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
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

    public let version: Int
    public let kind: Kind
    public let stream: Stream
    public var profile: CollectionObservationProfile { stream.profile }
    public let start: Date
    public let end: Date?

    /// Legacy version-six heart-rate predicates keep their original point-only meaning.
    public var usesOverlapPredicate: Bool { profile.isInterval || version >= 7 }

    var hasCurrentSemantics: Bool { version == Self.currentVersion(stream) }

    public init(profile: CollectionObservationProfile, kind: Kind, start: Date, end: Date? = nil) throws {
        try self.init(stream: Stream(profile), kind: kind, start: start, end: end)
    }

    public init(stream: Stream, kind: Kind, start: Date, end: Date? = nil) throws {
        try self.init(stream: stream, kind: kind, start: start, end: end, version: Self.currentVersion(stream))
    }

    private init(stream: Stream, kind: Kind, start: Date, end: Date?, version: Int) throws {
        guard Self.validDate(start), end.map(Self.validDate) ?? true,
              kind == .live ? end == nil : end.map({ $0 > start }) == true else { throw DefinitionError.invalidDefinition }
        self.version = version
        self.kind = kind
        self.stream = stream
        self.start = start
        self.end = end
    }

    /// Reject unknown versions, extra fields and noncanonical definitions rather than silently resetting their anchors.
    public init(bytes: Data) throws {
        guard (1...16_384).contains(bytes.count) else { throw DefinitionError.invalidDefinition }
        guard let stored = try? JSONDecoder().decode(Storage.self, from: bytes) else { throw DefinitionError.invalidDefinition }
        guard stored.adapter == "healthkit", stored.version == 6 || stored.version == Self.currentVersion(stored.stream) else {
            throw DefinitionError.invalidDefinition
        }
        try self.init(stream: stored.stream, kind: stored.kind, start: stored.start, end: stored.end, version: stored.version)
        guard try encoded() == bytes else { throw DefinitionError.invalidDefinition }
    }

    private static func currentVersion(_ stream: Stream) -> Int {
        stream.profile.measurement?.effective == .dateTimeOrPeriod ? 7 : 6
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Storage(adapter: "healthkit", version: version, stream: stream, kind: kind, start: start, end: end))
    }

    public func contains(_ sampleStart: Date, ending sampleEnd: Date? = nil) -> Bool {
        let permittedShape = usesOverlapPredicate ? profile.permitsEffectiveTime(hasEnd: sampleEnd != nil) : sampleEnd == nil
        guard Self.validDate(sampleStart), sampleEnd.map(Self.validDate) ?? true, permittedShape else {
            return false
        }
        return CollectionMeasurementSelection.includes(sampleStart: sampleStart, sampleEnd: sampleEnd, windowStart: start, windowEnd: end)
    }
}


extension HealthKitQueryDefinition {
    static func validDate(_ date: Date) -> Bool {
        (-62_135_596_800...253_402_300_799).contains(date.timeIntervalSince1970)
    }
}


extension HealthKitQueryDefinition {
    /// Independent anchored streams; existing names preserve queued version-six definitions.
    public struct Stream: RawRepresentable, Codable, CaseIterable, Hashable, Sendable {
        public static let heartRate = Self("heartRate", profile: .heartRate)
        public static let bodyWeight = Self("bodyWeight", profile: .bodyWeight)
        public static let sleepStage = Self("sleepStage", profile: .sleepStage)
        public static let workout = Self("workout", profile: .workout)
        public static let workoutRoute = Self("workoutRoute", profile: .workout)

        public static let allCases: [Self] = {
            let streams = CollectionObservationProfile.allCases.flatMap { profile -> [Self] in
                guard ![.heartRate, .bodyWeight, .sleepStage, .workout, .onWrist].contains(profile) else {
                    return []
                }
                return profile.nativeSources.map { Self($0.sourceTypeIdentifier, profile: profile) }
            }
            return [.heartRate, .bodyWeight, .sleepStage, .workout, .workoutRoute] + streams
        }()

        public let rawValue: String
        public let profile: CollectionObservationProfile

        public var timeBasis: CollectionTimeBasis {
            .required(profile: profile.rawValue, sourceTypeIdentifier: sourceTypeIdentifier)
        }

        /// The route toggle authorizes a workout companion; documents have their own source-bound profile scope.
        public var recordingProfile: String {
            self == .workoutRoute ? CollectionObservationProfile.healthKitRecording.rawValue : profile.rawValue
        }

        public var sourceTypeIdentifier: String? {
            profile.nativeSources.first { $0.sourceTypeIdentifier == rawValue }?.sourceTypeIdentifier ?? profile.nativeSourceTypeIdentifier
        }

        private init(_ rawValue: String, profile: CollectionObservationProfile) {
            self.rawValue = rawValue
            self.profile = profile
        }

        public init?(rawValue: String) {
            guard let value = Self.allCases.first(where: { $0.rawValue == rawValue }) else {
                    return nil
                }
            self = value
        }

        public init(_ profile: CollectionObservationProfile, sourceTypeIdentifier: String? = nil) throws {
            let matches = Self.allCases.filter { stream in
                stream.profile == profile && stream != .workoutRoute
                    && (sourceTypeIdentifier.map { $0 == stream.sourceTypeIdentifier } ?? true)
            }
            guard matches.count == 1, let value = matches.first else { throw DefinitionError.invalidDefinition }
            self = value
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            guard let value = Self(rawValue: rawValue) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported HealthKit stream")
            }
            self = value
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        func includes(_ requirement: Components.Schemas.CollectionPlanRequirement) -> Bool {
            requirement.sourceKind == .participantApp && requirement.profile == profile.rawValue
                && (requirement.sourceTypeIdentifier.map { $0 == sourceTypeIdentifier } ?? profile.permitsLegacyUnqualifiedSource)
                && (requirement.timeBasis ?? .measurementTime) == timeBasis
                && (self != .workoutRoute || requirement.includeWorkoutRoutes == true)
        }
    }
}
