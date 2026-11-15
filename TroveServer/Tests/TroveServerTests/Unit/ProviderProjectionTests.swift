//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import GroveFHIRContract
import GroveProviderFHIR
import ModelsR4
import Testing
@testable import TroveServer


struct ProviderProjectionTests {
    @Test
    func pressurePairRetainsComponentValuesAndExactProviderEvidenceInStudyView() throws {
        let context = try Self.context()
        let results = try WithingsFHIR.convert(.init(
            id: "1234", date: Date(timeIntervalSince1970: 1_700_000_000),
            measures: [.init(type: 9, value: 805, unit: -1), .init(type: 10, value: 12025, unit: -2)]
        ), context: context)
        let record = try #require(results.first?.record)
        let event = try FHIRPointProjection.project(validatedBytes: record.json, validatorIdentity: "synthetic-admission")
        let output = try #require(event.outputs.first)
        #expect(event.outputs.count == 1)
        #expect(output.value == .components)
        #expect(output.sourceTypeIdentifier == "getmeas:9+10")
        #expect(output.sourceRepositoryKind == .withings)
        let projection = try StudyPointProjection.project(
            event, outputs: [output.fullURL],
            subject: .init(system: IdentifierSystem("https://example.test/study-subject"), value: "study-participant")
        )
        let bundle = try JSONDecoder().decode(ModelsR4.Bundle.self, from: projection.json)
        let observation = try #require(bundle.entry?.compactMap { entry -> Observation? in
            if case .observation(let value)? = entry.resource { return value }
            return nil
        }.first)
        let quantities = observation.component?.compactMap { component -> Decimal? in
            if case .quantity(let value)? = component.value { return value.value?.value?.decimal }
            return nil
        }
        let expected = try Set([#require(Decimal(string: "80.5")), #require(Decimal(string: "120.25"))])
        #expect(Set(quantities ?? []) == expected)
        #expect(observation.meta?.profile?.isEmpty != false)
    }

    @Test
    func sourceMarkersCannotBeMixedOrInventedFromCallerMetadata() throws {
        let context = try Self.context()
        let results = try WithingsFHIR.convert(.init(
            id: "5678", date: Date(timeIntervalSince1970: 1_700_000_000), measures: [.init(type: 1, value: 72000, unit: -3)]
        ), context: context)
        let record = try #require(results.first?.record)
        let bundle = try JSONDecoder().decode(ModelsR4.Bundle.self, from: record.json)
        let observation = try #require(bundle.entry?.compactMap { entry -> Observation? in
            if case .observation(let value)? = entry.resource { return value }
            return nil
        }.first)
        var extensions = observation.extension ?? []
        extensions.append(Extension(url: Canonicals.healthKitSourceTypeExtension, value: .code("HKQuantityTypeIdentifierBodyMass")))
        #expect(throws: (any Error).self) { try FHIRSourceTypeEvidence.extract(extensions) }
    }

    private static func context() throws -> ProviderConversionContext {
        let producer = try ExchangeProducer(
            identityScope: .init(
                root: IdentifierSystem("https://example.test/provider-source"), keyID: "synthetic", epoch: KeyEpoch(1),
                key: SymmetricKey(data: Data(repeating: 0x35, count: 32))
            ),
            subject: .logical(.init(system: IdentifierSystem("https://example.test/participants"), value: "synthetic-participant")),
            application: .init(name: "Trove", bundleIdentifier: "org.example.Trove", version: "1"),
            host: .init(operatingSystemName: "Linux", operatingSystemVersion: "6")
        )
        return try .init(
            producer: producer, scope: .account(.init(system: IdentifierSystem("https://example.test/provider-account"), value: "account")),
            instant: Date(timeIntervalSince1970: 1_700_000_100), sourceTimeZone: #require(TimeZone(secondsFromGMT: 0))
        )
    }
}
