//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPITypes


/// Transfers one retained recording using a captured-session client. The event drainer owns scheduling and clinical custody.
public actor RecordingTransferDrainer {
    public enum Failure: Error, Equatable {
        case transferInProgress
        case authenticationRequired
        case unpreparedTransfer
        case transportFailed
        case invalidReceipt
        case receiptExpired
        case fileChanged
        case rejected(statusCode: Int)
    }

    let journal: EventDeliveryJournal
    let client: any APIProtocol
    private let validateSession: @Sendable () async throws -> Void
    private let now: @Sendable () -> Date
    private var isTransferring = false
    private var authenticationFailed = false

    /// Use the authenticated client and session-generation check for exactly this journal scope.
    public init(
        journal: EventDeliveryJournal,
        scope: EventDeliveryJournal.Scope,
        client: any APIProtocol,
        validateSession: @escaping @Sendable () async throws -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard journal.scope == scope else { throw DeliveryJournalError.wrongScope }
        self.journal = journal
        self.client = client
        self.validateSession = validateSession
        self.now = now
    }

    /// Recovers before resending, preserves exact transfer identity, and never retires the queue's recording file.
    public func transfer(_ recordingID: UUID) async throws -> Components.Schemas.RecordingTransferReceipt {
        guard !isTransferring else { throw Failure.transferInProgress }
        isTransferring = true
        defer { isTransferring = false }
        try await checkSession()
        guard let retained = try await journal.recordingTransfer(for: recordingID) else { throw Failure.unpreparedTransfer }
        try await checkSession()
        if let receipt = retained.usableReceipt(at: now()) {
            return receipt
        }
        if let receipt = try await lookup(retained) {
            try await retain(receipt, for: retained)
            if receipt.expiresAt > now(), receipt.verifiedAt <= now() {
                return receipt
            }
        }
        // A receipt lookup is allowed after revocation, but a new upload requires the active installation.
        let setup = try await journal.activeSource(retained.sourceID)
        let credential = try await journal.installationCredential(for: setup.localID).base64EncodedString()
        try await checkSession()
        let url = try await journal.recordingURL(for: recordingID)
        let content = retained.commitment.declaration.content
        let body: RecordingUploadBody
        do {
            body = try RecordingUploadBody(url: url, byteCount: content.storedByteCount, sha256: content.storedSHA256)
        } catch {
            try Task.checkCancellation()
            throw Failure.fileChanged
        }
        try await checkSession()
        let registration = try await register(retained, installationID: setup.localID, credential: credential)
        do {
            try retained.commitment.verify(registration, sourceID: retained.sourceID, transferID: recordingID)
        } catch { throw Failure.invalidReceipt }
        try await journal.recordRecordingRegistration(registration, for: recordingID)
        try await checkSession()
        let receipt = try await upload(retained, body: body, installationID: setup.localID, credential: credential)
        try await retain(receipt, for: retained)
        guard receipt.expiresAt > now(), receipt.verifiedAt <= now() else { throw Failure.receiptExpired }
        return receipt
    }

    func checkSession() async throws {
        try Task.checkCancellation()
        guard !authenticationFailed else { throw Failure.authenticationRequired }
        do { try await validateSession() } catch {
            try Task.checkCancellation()
            authenticationFailed = true
            throw Failure.authenticationRequired
        }
        try Task.checkCancellation()
    }

    func rejected(_ code: Int) throws -> Never {
        if code == 401 {
            authenticationFailed = true
            throw Failure.authenticationRequired
        }
        throw Failure.rejected(statusCode: code)
    }

    private func retain(_ receipt: Components.Schemas.RecordingTransferReceipt, for transfer: DeliveryRecordingTransfer) async throws {
        try await checkSession()
        do {
            try transfer.commitment.verify(receipt, sourceID: transfer.sourceID, transferID: transfer.transferID)
        } catch { throw Failure.invalidReceipt }
        try await journal.recordRecordingReceipt(receipt, for: transfer.transferID)
        try await checkSession()
    }
}
