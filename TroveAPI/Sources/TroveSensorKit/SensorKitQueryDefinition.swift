//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveSensorKitFHIR


/// One immutable SensorKit sensor/device partition; all partitions share the registered source.
public struct SensorKitQueryDefinition: Codable, Sendable, Equatable {
    private let version: Int
    public let sourceToken: String
    public let deviceProductType: String
    public let replayAuthority: String?

    public init(sourceToken: String, deviceProductType: String, replayAuthority: String? = nil) throws {
        version = 1
        self.sourceToken = sourceToken
        self.deviceProductType = deviceProductType
        self.replayAuthority = replayAuthority
        try validate()
    }

    public init(encoded: Data) throws {
        guard (1...16_384).contains(encoded.count) else { throw SensorKitAcquisition.AcquisitionError.invalidBatch }
        self = try JSONDecoder().decode(Self.self, from: encoded)
        try validate()
    }

    public func encoded() throws -> Data {
        try validate()
        return try JSONEncoder().encode(self)
    }

    private func validate() throws {
        guard version == 1, (1...256).contains(deviceProductType.utf8.count),
              replayAuthority.map({ $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) ?? true,
              let entry = SensorKitCatalog.current.entry(sourceToken: sourceToken),
              entry.implementedOutput != nil else { throw SensorKitAcquisition.AcquisitionError.invalidBatch }
    }
}
