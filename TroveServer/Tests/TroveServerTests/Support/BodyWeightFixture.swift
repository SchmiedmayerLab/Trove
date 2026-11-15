// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import TroveAPIServer
@testable import TroveServer
import Vapor


/// Grove's body-mass-user-entered golden, copied byte-for-byte. Local rekeying is
/// synthetic custody evidence; the full-validation lane verifies the preserved graph.
enum BodyWeightFixture {
    static func event(source: SourceBinding, app: Application, fullValidation: Bool = false) async throws -> ValidatedExchangeEvent {
        let url = try #require(Bundle.module.url(forResource: "HealthKitBodyWeightEvent", withExtension: "json"))
        let original = try fullValidation
            ? ImmutablePointEventFixture.bytes(source: source, fixtureURL: url)
            : LocalPointEventFixture.bytes(source: source, fixtureURL: url)
        let system = try Components.Schemas.ParticipantSource(source).nativeRecordIdentifierSystem()
        let bytes = try NativeIdentifierFixture.adding([["system": system.rawValue, "value": NativeIdentifierFixture.uuid]], to: original)
        let identity = try await fullValidation ? FHIRValidationClient(application: app).validate(bytes) : "synthetic-test-only"
        return try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: identity)
    }
}
