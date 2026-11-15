//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

/// One immutable replay receipt and its durable journal progress metadata.
public struct SensorKitRetainedBatch: Sendable {
    public let rowID: Int64
    public let evidence: SensorKitBatchEvidence
    public let stagedAuthority: String?
}
