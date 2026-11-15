//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIClient


/// Identifies the registration's primary query before SensorKit reveals its device partitions.
/// Partition queries own acquisition receipts; the primary query never advances a native cursor.
public struct SensorKitSourceDefinition: Codable, Sendable {
    private let version: Int
    private let repository: Components.Schemas.NativeSourceRepository

    public init() {
        version = 1
        repository = .sensorkit
    }

    public init(encoded: Data) throws {
        guard (1...1024).contains(encoded.count) else { throw SensorKitAcquisition.AcquisitionError.invalidBatch }
        self = try JSONDecoder().decode(Self.self, from: encoded)
        guard version == 1, repository == .sensorkit else { throw SensorKitAcquisition.AcquisitionError.invalidBatch }
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
}
