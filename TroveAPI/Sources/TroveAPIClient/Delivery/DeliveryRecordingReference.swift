//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Immutable queue ownership and stored-byte commitment. A transport receipt does not retire this file.
public struct DeliveryRecordingReference: Sendable, Equatable {
    public let id: UUID
    public let relativePath: String
    public let byteCount: Int
    public let sha256: String
}
