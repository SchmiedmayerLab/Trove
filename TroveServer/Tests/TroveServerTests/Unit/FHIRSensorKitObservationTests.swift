//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveSensorKitFHIR
import ModelsR4
import Testing
@testable import TroveServer


struct FHIRSensorKitObservationTests {
    @Test("The receiver retains each implemented SensorKit source's exact graph and collection interval", arguments: [
        SensorKitStructuredContract.onWrist, .visit, .messagesUsage, .phoneUsage, .sleepSession
    ])
    func acceptsStructuredGraph(_ contract: SensorKitStructuredContract) async throws {
        let bytes = try await FHIRSensorKitFixture.bytes(contract)
        let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "synthetic-receiver-test")
        let output = try #require(event.outputs.first)
        let source = try #require(SensorKitCatalog.current.entries.first { $0.structuredContract == contract })
        #expect(event.outputs.count == 1)
        #expect(event.rawBytes == bytes)
        #expect(output.sourceRepositoryKind == .sensorKit)
        #expect(output.sourceTypeIdentifier == source.sourceToken)
        #expect(output.profile == source.implementedOutput?.observation?.primaryProfile)
        #expect(output.measurementBounds == (try ClinicalMeasurementBounds(start: FHIRSensorKitFixture.start, end: FHIRSensorKitFixture.end)))
        let projected = try StudyPointProjection.project(
            event, outputs: [output.fullURL], subject: .init(system: IdentifierSystem("https://example.test/study-subject"), value: "study-participant")
        )
        let before = try FHIRSensorKitFixture.observation(bytes), after = try FHIRSensorKitFixture.observation(projected.json)
        #expect(before.value == after.value)
        #expect(before.component == after.component)
        #expect(before.focus == after.focus)
    }

    @Test("A source marker cannot borrow another sensor's profile")
    func refusesCrossSourceMarker() async throws {
        var observation = try FHIRSensorKitFixture.observation(await FHIRSensorKitFixture.bytes(.onWrist))
        let other = try #require(SensorKitCatalog.current.entries.first { $0.structuredContract == .phoneUsage })
        observation.extension = [
            Extension(url: Canonicals.sensorKitSourceTypeExtension, value: .code(FHIRPrimitive(FHIRString(other.sourceTypeCode))))
        ]
        #expect(throws: (any Error).self) { try FHIRObservationValueProjection(observation: observation, quantityText: nil) }
    }

    @Test("Visit uncertainty windows cannot hide time outside their declared measurement interval")
    func refusesOutlyingVisitComponent() async throws {
        var observation = try FHIRSensorKitFixture.observation(await FHIRSensorKitFixture.bytes(.visit))
        let index = try #require(observation.component?.firstIndex { if case .period? = $0.value { true } else { false } })
        observation.component?[index].value = .period(Period(
            end: FHIRPrimitive(try DateTime("2026-08-17T23:30:05Z")), start: FHIRPrimitive(try DateTime("2026-08-17T23:29:59Z"))
        ))
        #expect(throws: (any Error).self) { try FHIRObservationValueProjection(observation: observation, quantityText: nil) }
    }

    @Test("Visit location references remain logical; an external resource cannot enter the graph")
    func refusesLiteralVisitLocation() async throws {
        var observation = try FHIRSensorKitFixture.observation(await FHIRSensorKitFixture.bytes(.visit))
        observation.focus = [Reference(reference: "https://example.test/Location/foreign")]
        #expect(throws: (any Error).self) { try FHIRObservationValueProjection(observation: observation, quantityText: nil) }
    }
}
