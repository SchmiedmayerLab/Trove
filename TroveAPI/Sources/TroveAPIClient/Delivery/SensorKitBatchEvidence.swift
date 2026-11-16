//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Immutable local evidence for reproducing an already allocated SensorKit acquisition batch.
/// Permission and clinical payloads remain outside this receipt. The total journal budget includes every retained row.
public struct SensorKitBatchEvidence: Sendable, Equatable {
    private struct Representation: Codable, Sendable, Equatable {
        let version: Int
        let sourceTypeIdentifier: String
        let deviceProductType: String
        let coordinate: String
        let effectiveStart: Date
        let effectiveEnd: Date
        let replayToken: Data
        let firstReceipt: Data
    }

    private let representation: Representation
    public var sourceTypeIdentifier: String { representation.sourceTypeIdentifier }
    public var deviceProductType: String { representation.deviceProductType }
    public var coordinate: String { representation.coordinate }
    public var effectiveStart: Date { representation.effectiveStart }
    public var effectiveEnd: Date { representation.effectiveEnd }
    public var replayToken: Data { representation.replayToken }
    public var firstReceipt: Data { representation.firstReceipt }

    public init(
        sourceTypeIdentifier: String,
        deviceProductType: String,
        coordinate: String,
        effectiveStart: Date,
        effectiveEnd: Date,
        replayToken: Data,
        firstReceipt: Data
    ) throws {
        representation = Representation(
            version: 1,
            sourceTypeIdentifier: sourceTypeIdentifier,
            deviceProductType: deviceProductType,
            coordinate: coordinate,
            effectiveStart: effectiveStart,
            effectiveEnd: effectiveEnd,
            replayToken: replayToken,
            firstReceipt: firstReceipt
        )
        try validate()
    }

    init(encoded: Data) throws {
        guard (1...131_072).contains(encoded.count) else { throw DeliveryJournalError.corruptJournal }
        do {
            representation = try JSONDecoder().decode(Representation.self, from: encoded)
            try validate()
        } catch {
            throw DeliveryJournalError.corruptJournal
        }
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let result = try encoder.encode(representation)
        guard result.count <= 131_072 else { throw DeliveryJournalError.capacityExceeded }
        return result
    }

    private func validate() throws {
        let strings = [(sourceTypeIdentifier, 512), (deviceProductType, 256), (coordinate, 1024)]
        guard representation.version == 1,
              strings.allSatisfy({ (1...$0.1).contains($0.0.utf8.count) && !$0.0.utf8.contains(0) }),
              (1...16_384).contains(replayToken.count), (1...65_536).contains(firstReceipt.count),
              effectiveStart.timeIntervalSince1970.isFinite, effectiveEnd.timeIntervalSince1970.isFinite,
              effectiveEnd >= effectiveStart else { throw DeliveryJournalError.invalidConfiguration }
    }
}
