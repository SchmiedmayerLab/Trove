//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveHealthKit
import TroveAPITypes


/// A current online instruction for one finite historical sweep, separate from cached enrollment authority.
public struct NativeCollectionReconciliation: Sendable {
    public enum ValidationError: Error { case invalidInstruction, expired, scopeChanged }

    public let id: UUID
    public let sourceID: UUID
    public let enrollmentID: UUID
    public let consentID: UUID
    public let expiresAt: Date
    public let definition: HealthKitQueryDefinition
    public let stateVersion: Int64
    let instruction: Components.Schemas.NativeCollectionReconciliationInstruction

    public init(
        _ instruction: Components.Schemas.NativeCollectionReconciliationInstruction,
        plan: Components.Schemas.ParticipantCollectionPlan,
        sourceID: UUID,
        at now: Date = .now
    ) throws {
        let dates = [instruction.issuedAt, instruction.expiresAt, instruction.start, instruction.end, now]
        guard dates.allSatisfy(HealthKitQueryDefinition.validDate),
              instruction.start < instruction.end, instruction.end <= instruction.issuedAt,
              instruction.issuedAt < instruction.expiresAt,
              let id = UUID(uuidString: instruction.id), let enrollmentID = UUID(uuidString: instruction.enrollmentId),
              let consentID = UUID(uuidString: instruction.consentId),
              UUID(uuidString: instruction.sourceId) == sourceID else {
            throw ValidationError.invalidInstruction
        }
        // Like enrollment end, the lease is enforced on the device clock; a server instant slightly ahead of it is not a fault.
        guard now < instruction.expiresAt else { throw ValidationError.expired }
        guard instruction.enrollmentId == plan.enrollmentId, instruction.studyId == plan.studyId,
              instruction.stateVersion == plan.stateVersion,
              plan.endsAt.map({ $0 <= instruction.issuedAt }) == true else { throw ValidationError.scopeChanged }
        let stream = try Self.stream(instruction)
        guard plan.windows.contains(where: { window in
            window.consentId == instruction.consentId && window.publicationId == instruction.publicationId
                && window.revision == instruction.revision && window.requirements.contains { requirement in
                    stream.includes(requirement) && requirement.start == instruction.start && requirement.end == instruction.end
                }
        }) else { throw ValidationError.scopeChanged }
        self.id = id
        self.sourceID = sourceID
        self.enrollmentID = enrollmentID
        self.consentID = consentID
        self.expiresAt = instruction.expiresAt
        self.stateVersion = instruction.stateVersion
        self.definition = try HealthKitQueryDefinition(stream: stream, kind: .historical, start: instruction.start, end: instruction.end)
        self.instruction = instruction
    }

    private static func stream(_ value: Components.Schemas.NativeCollectionReconciliationInstruction) throws -> HealthKitQueryDefinition.Stream {
        if value.profile == CollectionObservationProfile.healthKitRecording.rawValue,
           value.sourceTypeIdentifier == SampleType.workoutRoute.hkSampleType.identifier, value.includeWorkoutRoutes == true {
            return .workoutRoute
        }
        guard let stream = [HealthKitQueryDefinition.Stream.sleepStage, .workout].first(where: {
            $0.sourceTypeIdentifier == value.sourceTypeIdentifier && $0.recordingProfile == value.profile
        }) else { throw ValidationError.invalidInstruction }
        return stream
    }

    /// Neither issuance nor renewal changes the measurement predicate or the accepted consent.
    public func renews(_ previous: Self) -> Bool {
        id == previous.id && sourceID == previous.sourceID && enrollmentID == previous.enrollmentID
            && consentID == previous.consentID && stateVersion == previous.stateVersion && definition == previous.definition
            && instruction.publicationId == previous.instruction.publicationId && instruction.revision == previous.instruction.revision
            && instruction.issuedAt >= previous.instruction.issuedAt
    }

    public func contains(sampleStart: Date, sampleEnd: Date) -> Bool {
        definition.contains(sampleStart, ending: sampleEnd)
    }
}
