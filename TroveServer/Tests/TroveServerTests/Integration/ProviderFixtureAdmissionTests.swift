//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import GroveProviderFHIR
import Testing
@testable import TroveServer


struct ProviderFixtureAdmissionTests {
    private struct Issue: Decodable {
        let severity: String
    }

    /// A validator outcome without issues omits the list.
    private struct Outcome: Decodable {
        enum CodingKeys: CodingKey {
            case issue
        }

        let issue: [Issue]

        init(from decoder: any Decoder) throws {
            issue = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([Issue].self, forKey: .issue) ?? []
        }
    }

    private struct Result: Decodable {
        let path: String
        let outcome: Outcome
    }

    private struct Evidence: Decodable {
        let fixtureSHA256: [String: String]
        let outcomes: [Result]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TROVE_TEST_PROVIDER_FIXTURES"] != nil))
    func officiallyValidatedStructuredProviderFixturesPassReceiverAdmission() throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try #require(environment["TROVE_TEST_PROVIDER_FIXTURES"]), isDirectory: true)
        let report = URL(fileURLWithPath: try #require(environment["TROVE_TEST_PROVIDER_VALIDATION_RESULTS"]))
        let evidence = try JSONDecoder().decode(Evidence.self, from: Data(contentsOf: report))
        for provider in ProviderCapabilities.Provider.allCases {
            let capabilities = ProviderCapabilities.sources(for: provider).filter { $0.conversionSupport == .structured }
            #expect(!capabilities.isEmpty)
            for capability in capabilities {
                let file = capability.token.utf8.map { String(format: "%02x", $0) }.joined() + ".json"
                let path = provider.rawValue + "/" + file
                let bytes = try Data(contentsOf: directory.appendingPathComponent(path))
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                #expect(evidence.fixtureSHA256[path] == digest)
                let result = try #require(evidence.outcomes.first { $0.path == path })
                #expect(result.outcome.issue.allSatisfy { !["error", "fatal"].contains($0.severity) })
                let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "verified-fixture-" + digest)
                #expect(!event.outputs.isEmpty)
                #expect(event.outputs.allSatisfy { $0.sourceTypeIdentifier == capability.token })
                #expect(event.outputs.allSatisfy { $0.sourceRepositoryKind?.rawValue == provider.rawValue })
            }
        }
    }
}
