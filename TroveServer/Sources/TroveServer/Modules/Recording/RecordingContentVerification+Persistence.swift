//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


extension RecordingContentVerification {
    private struct Evidence: Codable {
        let first: Date?
        let last: Date?
        let rows: RecordingRowExtent?
        let attachmentSHA1: Data
    }

    /// Stored only after complete decoding and integrity verification, in the custody transaction.
    /// This is internal evidence, never a client-supplied alternative to content verification.
    var serialized: String {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try encoder.encode(Evidence(
                first: bounds.first, last: bounds.last, rows: bounds.rows, attachmentSHA1: attachmentSHA1
            )), as: UTF8.self)
        }
    }

    init(restoring serialized: String) throws {
        do {
            guard (1...1024).contains(serialized.utf8.count) else { throw FHIRValidationClient.invalid }
            let evidence = try JSONDecoder().decode(Evidence.self, from: Data(serialized.utf8))
            guard evidence.attachmentSHA1.count == 20 else { throw FHIRValidationClient.invalid }
            self.init(
                bounds: try RecordingRouteBounds(first: evidence.first, last: evidence.last, rows: evidence.rows),
                attachmentSHA1: evidence.attachmentSHA1
            )
        } catch {
            throw ServerError.internalServerError("Retained recording evidence is unavailable")
        }
    }
}
