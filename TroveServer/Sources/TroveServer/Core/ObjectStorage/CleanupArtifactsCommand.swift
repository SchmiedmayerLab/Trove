//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Vapor


/// Uses restricted database and cleanup-capable storage credentials; not exposed through HTTP.
struct CleanupArtifactsCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "limit", help: "Maximum artifacts to process (1–100; default 100).") var limit: Int?
    }

    let auditConfiguration: AuditConfiguration

    var help: String { "Remove expired, unaccepted artifacts while retaining durable recovery records." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let limit = signature.limit ?? 100
        guard (1...100).contains(limit) else { throw ArtifactStore.Failure.invalidCleanupBatch }
        let storage = try ObjectStorageService(provider: S3ObjectStorageProvider(application: context.application, config: .init()))
        let report: ArtifactCleanupReport
        do {
            report = try await ArtifactStore(database: context.application.db(.psql), storage: storage)
                .cleanup(limit: limit, auditContext: .artifactCleanup(configuration: auditConfiguration))
        } catch {
            try? await storage.shutdown()
            throw error
        }
        try await storage.shutdown()
        context.console.print("Artifact cleanup: \(report.deleted) delete requests completed; \(report.failed) failed.")
        guard report.failed == 0 else { throw ServerError.internalServerError("Artifact cleanup requires retry") }
    }
}
