//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Complete recording bytes associated with one relative attachment path in an immutable record.
/// Supply a frozen source such as Grove's RecordingFile.readChunks. Each chunk is at most 64 KiB.
/// The journal consumes the source synchronously on its executor and owns the durable copy after staging.
public struct DeliveryRecording: Sendable {
    public let relativePath: String
    public let byteCount: Int
    let readChunks: @Sendable (_ consume: (Data) throws -> Void) throws -> Void

    public init(
        relativePath: String,
        byteCount: Int,
        readChunks: @escaping @Sendable (_ consume: (Data) throws -> Void) throws -> Void
    ) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.readChunks = readChunks
    }
}
