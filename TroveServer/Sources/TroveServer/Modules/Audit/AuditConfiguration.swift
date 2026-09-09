//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

/// Deployment-supplied revision, never request metadata or an invented build identity.
struct AuditConfiguration: Sendable {
    enum Failure: Error { case invalidRevision }

    let applicationRevision: String?

    init(applicationRevision: String?) throws {
        if let applicationRevision {
            guard (1...128).contains(applicationRevision.utf8.count),
                  applicationRevision.utf8.allSatisfy({
                      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                          || [UInt8(45), 46, 47, 58, 95].contains($0)
                  }) else { throw Failure.invalidRevision }
        }
        self.applicationRevision = applicationRevision
    }
}


extension AuditEvent.Context {
    /// The cleanup service is the actor; a shell invocation does not establish a human initiator.
    static func artifactCleanup(configuration: AuditConfiguration? = nil) -> Self {
        .init(
            actor: .init(issuer: "urn:trove:system", subject: "artifact-cleanup"),
            applicationRevision: configuration?.applicationRevision
        )
    }
}
