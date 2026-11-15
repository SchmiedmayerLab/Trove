//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

extension EventSubmissionLimits {
    /// Deployment and producer operating budgets within the shared wire ceilings.
    /// Defaults retain the existing workload policy; larger options need workload verification.
    public struct Configuration: Sendable, Equatable {
        public enum Failure: Error { case invalidLimits }
        public static let standard = Self()

        public let recordBytes: Int
        public let bundleBytes: Int
        public let envelopeBytes: Int
        public let batchRecords: Int
        public var recordBase64Bytes: Int { ((recordBytes + 2) / 3) * 4 }
        public var bundleBase64Bytes: Int { ((bundleBytes + 2) / 3) * 4 }

        private init() {
            recordBytes = 4 * 1024 * 1024
            bundleBytes = recordBytes + 1024
            envelopeBytes = 6 * 1024 * 1024
            batchRecords = 16
        }

        public init(settings: [String: String]) throws {
            try self.init(
                recordBytes: CollectionCapacitySetting.recordBytes.read(from: settings, default: Self.standard.recordBytes),
                bundleBytes: CollectionCapacitySetting.bundleBytes.read(from: settings, default: Self.standard.bundleBytes),
                envelopeBytes: CollectionCapacitySetting.envelopeBytes.read(from: settings, default: Self.standard.envelopeBytes),
                batchRecords: CollectionCapacitySetting.batchRecords.read(from: settings, default: Self.standard.batchRecords)
            )
        }

        public init(recordBytes: Int, bundleBytes: Int, envelopeBytes: Int, batchRecords: Int = 16) throws {
            guard (1...EventSubmissionLimits.maximumEventBytes).contains(recordBytes),
                  (recordBytes + 1024...EventSubmissionLimits.maximumBundleBytes).contains(bundleBytes),
                  (1...EventSubmissionLimits.maximumEnvelopeBytes).contains(envelopeBytes),
                  envelopeBytes >= ((bundleBytes + 2) / 3) * 4 + 1024,
                  (1...EventSubmissionLimits.maximumBatchEvents).contains(batchRecords) else {
                throw Failure.invalidLimits
            }
            self.recordBytes = recordBytes
            self.bundleBytes = bundleBytes
            self.envelopeBytes = envelopeBytes
            self.batchRecords = batchRecords
        }
    }
}
