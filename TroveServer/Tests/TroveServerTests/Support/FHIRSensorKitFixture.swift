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
import GroveSensorKitFHIR
import ModelsR4
import Testing


/// Exact Grove-produced graphs for receiver tests, independent of native query availability.
enum FHIRSensorKitFixture {
    static let start = Date(timeIntervalSince1970: 1_787_009_400)
    static let end = start.addingTimeInterval(60)
    static let sourceID = SensorKitSourceRecordID(UUID(uuid: (
        0x87, 0x9d, 0x9e, 0xa2, 0x21, 0xcb, 0x45, 0x27, 0xb5, 0x9b, 0x28, 0x31, 0xdc, 0x4c, 0x84, 1
    )))

    static func record(_ contract: SensorKitStructuredContract) throws -> SensorKitRecord {
        switch contract {
        case .onWrist:
            .onWrist(.init(
                sourceRecordID: sourceID, timestamp: end, onWrist: true, currentStateStart: start, wristLocation: .left, crownOrientation: .right
            ))
        case .visit:
            .visit(.init(
                sourceRecordID: sourceID,
                locationCategory: .home,
                distanceFromHomeMeters: 42,
                arrivalWindow: DateInterval(start: start, duration: 5),
                departureWindow: DateInterval(start: end.addingTimeInterval(-5), end: end),
                locationID: UUID(uuidString: "248b854a-8d64-4308-9ee0-d220e7d747d3")
            ))
        case .messagesUsage:
            .messagesUsage(.init(
                sourceRecordID: sourceID,
                timestamp: start,
                durationSeconds: 60,
                totalIncomingMessages: 12,
                totalOutgoingMessages: 8,
                totalUniqueContacts: 3
            ))
        case .phoneUsage:
            .phoneUsage(.init(
                sourceRecordID: sourceID,
                timestamp: start,
                durationSeconds: 60,
                totalIncomingCalls: 2,
                totalOutgoingCalls: 3,
                totalPhoneCallDurationSeconds: 35,
                totalUniqueContacts: 4
            ))
        case .sleepSession:
            .sleepSession(.init(sourceRecordID: sourceID, session: DateInterval(start: start, end: end)))
        default: throw CocoaError(.featureUnsupported)
        }
    }

    static func bytes(_ contract: SensorKitStructuredContract) async throws -> Data {
        try await bytes(record(contract))
    }

    static func bytes(_ record: SensorKitRecord) async throws -> Data {
        let producer = try ExchangeProducer(
            identityScope: .init(
                root: IdentifierSystem("https://example.test/sensor-source"),
                keyID: "synthetic",
                epoch: KeyEpoch(1),
                key: SymmetricKey(data: Data(repeating: 0x35, count: 32))
            ),
            subject: .logical(.init(system: IdentifierSystem("https://example.test/participants"), value: "synthetic-participant")),
            application: .init(name: "Trove", bundleIdentifier: "org.example.Trove", version: "1"),
            host: .init(operatingSystemName: "Linux", operatingSystemVersion: "6")
        )
        let exporter = try SensorKitFHIRExporter(
            producer: producer,
            repositoryScope: .init(system: IdentifierSystem("https://example.test/sensor-repository"), value: "primary"),
            visitLocationIdentifierSystem: IdentifierSystem("https://example.test/sensor-location")
        )
        var results: [Data] = []
        try await exporter.export(
            [record], sourceTimeZone: #require(TimeZone(secondsFromGMT: 0)), recordingDevice: nil, at: end.addingTimeInterval(10)
        ) { result in
            switch result.outcome {
            case .record(let record): results.append(record.json)
            case .refused(let failure): throw failure
            }
        }
        try #require(results.count == 1)
        return try #require(results.first)
    }

    static func observation(_ bytes: Data) throws -> Observation {
        let bundle = try JSONDecoder().decode(ModelsR4.Bundle.self, from: bytes)
        return try #require(bundle.entry?.compactMap { entry -> Observation? in
            if case .observation(let observation)? = entry.resource {
                return observation
            }
            return nil
        }.first)
    }
}
