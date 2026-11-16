//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Vapor


/// Uses the restricted database credentials; not exposed through HTTP.
struct ReverseRetractionCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "event", help: "Custody event ID of the retraction to reverse.") var event: String?
    }

    let auditConfiguration: AuditConfiguration

    var help: String { "Reverse one source-record retraction. The retained record becomes eligible again; no history is rewritten." }

    func run(using context: CommandContext, signature: Signature) async throws {
        guard let eventID = signature.event.flatMap(UUID.init(uuidString:)) else {
            throw ServerError.badRequest("A retraction event ID is required")
        }
        let reversed = try await ClinicalEventStore(database: context.application.db(.psql))
            .reverseRetraction(eventID: eventID, auditContext: .retractionReversal(configuration: auditConfiguration))
        context.console.print(reversed ? "Retraction reversed." : "Retraction was already reversed.")
    }
}
