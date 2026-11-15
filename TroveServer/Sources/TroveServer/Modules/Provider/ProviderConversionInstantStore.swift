//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Fluent
import Foundation
import GroveFHIRContract
import GroveProviderFHIR
import SQLKit
import TroveAPITypes


/// The same upstream content and converter facts retain one conversion instant across queries, retries and restarts.
struct ProviderConversionInstantStore: Sendable {
    let database: any Database

    // The inputs are the exact source/converter identity, rather than caller-supplied event identifiers.
    // swiftlint:disable:next function_parameter_count
    func instant(
        nativeID: String, evidence: Data, authority: ProviderWorkerAuthority, producer: ExchangeProducer,
        scope: ProviderConversionContext.Scope, facts: ProviderAcquisitionFacts, acquiredAt: Date
    ) async throws -> Date {
        guard !nativeID.isEmpty, nativeID.utf8.count <= 512,
              (1...EventSubmissionLimits.maximumEventBytes).contains(evidence.count) else { throw ProviderFailure.invalidPayload }
        let fingerprint = SHA256.hash(data: evidence).map { String(format: "%02x", $0) }.joined()
        let encodedFacts = try ProviderSQL.encode(facts, maximumBytes: 16_384)
        let converterDigest = SHA256.hash(data: Data(encodedFacts.utf8)).map { String(format: "%02x", $0) }.joined()
        return try await database.transaction { transaction in
            let authorized = try await authority.lock(on: transaction)
            guard let provider = ConnectedProvider(rawValue: authorized.source.repositoryKind.rawValue) else { throw ProviderFailure.fenced }
            let context = ProviderConversionContext(
                producer: producer, scope: scope, instant: acquiredAt, sourceTimeZone: .gmt
            )
            let source = try context.sourceIdentity(
                provider: provider.converter, sourceType: authority.sourceToken, nativeRecordID: nativeID
            )
            // Hash only an already opaque identifier, never the participant's clear upstream key.
            let nativeDigest = SHA256.hash(data: Data(source.identifier.identifier.value.utf8))
                .map { String(format: "%02x", $0) }.joined()
            let sql = try ProviderSQL.sql(transaction)
            if let row = try await sql.raw("""
                SELECT converted_at, source_evidence FROM provider_conversion_instants WHERE source_id = \(bind: authorized.source.id)
                    AND source_token = \(bind: authority.sourceToken) AND native_identifier_digest = \(bind: nativeDigest)
                    AND content_fingerprint = \(bind: fingerprint) AND converter_fingerprint = \(bind: converterDigest)
                """).first() {
                guard try row.decode(column: "source_evidence", as: Data.self) == evidence else { throw ProviderFailure.fenced }
                return try row.decode(column: "converted_at", as: Date.self)
            }
            let retained = Date(timeIntervalSince1970: (acquiredAt.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
            try await sql.raw("""
                INSERT INTO provider_conversion_instants (
                    id, source_id, source_token, native_identifier_digest, content_fingerprint, converter_fingerprint, source_evidence, converted_at
                ) VALUES (
                    \(bind: UUID()), \(bind: authorized.source.id), \(bind: authority.sourceToken), \(bind: nativeDigest),
                    \(bind: fingerprint), \(bind: converterDigest), \(bind: evidence), \(bind: retained)
                )
                """).run()
            return retained
        }
    }
}
