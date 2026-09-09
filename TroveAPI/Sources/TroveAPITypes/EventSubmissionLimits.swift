//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

/// Shared wire bounds for custody commitments, client packing and server admission.
/// Changes must also update the OpenAPI contract and its generated clients.
public enum EventSubmissionLimits {
    /// Original event bytes, before base64 encoding.
    public static let maximumEventBytes = 4 * 1024 * 1024
    /// Aggregate base64 UTF-8 length, shared by single-event and batch requests.
    public static let maximumBase64Bytes = ((maximumEventBytes + 2) / 3) * 4
    /// Complete JSON envelope, including consent targets and framing.
    public static let maximumEnvelopeBytes = 6 * 1024 * 1024
    /// Independently committed events in one source-specific request.
    public static let maximumBatchEvents = 16
}
