//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPITypes


/// Retained transfer identity and exact evidence. Neither a registration nor an upload receipt establishes clinical custody.
public struct DeliveryRecordingTransfer: Sendable {
    public let sourceID: UUID
    public let transferID: UUID
    public let commitment: RecordingTransferCommitment
    public let registration: Components.Schemas.RecordingTransferRegistration?
    public let receipt: Components.Schemas.RecordingTransferReceipt?

    public func usableReceipt(at date: Date) -> Components.Schemas.RecordingTransferReceipt? {
        guard let receipt, date >= receipt.verifiedAt, date < receipt.expiresAt else {
            return nil
        }
        return receipt
    }
}
