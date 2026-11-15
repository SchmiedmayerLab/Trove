//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveSensorKitFHIR


/// Local retry evidence within the journal's existing opaque query cursor.
struct SensorKitBatchReceipt: Codable {
    enum Phase: String, Codable { case prepared, staged }
    static let maximumFactsBytes = 16_384
    let version: Int
    let coordinate: String
    let sourceToken: String
    let deviceProductType: String
    let identities: [UUID]
    let digests: [Data]
    let facts: Data
    var phase: Phase

    init(batch: SensorKitAcquisition.Batch) throws {
        guard batch.inputs.allSatisfy({ $0.sourceToken == batch.sourceToken }) else {
            throw SensorKitAcquisition.AcquisitionError.invalidBatch
        }
        version = batch.usesRecordingSlices ? 2 : 1
        coordinate = batch.coordinate
        sourceToken = batch.sourceToken
        deviceProductType = batch.deviceProductType
        identities = batch.inputs.map { $0.sourceID.uuid }
        digests = batch.inputs.map(\.digest)
        facts = try batch.facts.encoded(maximumByteCount: Self.maximumFactsBytes)
        phase = .prepared
        try validate()
    }

    init(encoded: Data) throws {
        guard (1...65_536).contains(encoded.count) else { throw SensorKitAcquisition.AcquisitionError.invalidBatch }
        self = try JSONDecoder().decode(Self.self, from: encoded)
        try validate()
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(self)
        guard bytes.count <= 65_536 else { throw SensorKitAcquisition.AcquisitionError.invalidBatch }
        return bytes
    }

    func verify(_ retry: Self) throws {
        guard version == retry.version, coordinate == retry.coordinate, sourceToken == retry.sourceToken,
              deviceProductType == retry.deviceProductType, identities == retry.identities, digests == retry.digests else {
            throw SensorKitAcquisition.AcquisitionError.retryMismatch
        }
    }

    private func validate() throws {
        guard (1...2).contains(version), (1...1024).contains(coordinate.utf8.count),
              (1...256).contains(sourceToken.utf8.count), (1...256).contains(deviceProductType.utf8.count),
              identities.count <= 128, Set(identities).count == identities.count,
              digests.count == identities.count, digests.allSatisfy({ $0.count == 32 }),
              (1...Self.maximumFactsBytes).contains(facts.count) else { throw SensorKitAcquisition.AcquisitionError.invalidBatch }
        _ = try SensorKitBatchSnapshot(encoded: facts, maximumByteCount: Self.maximumFactsBytes)
    }
}
