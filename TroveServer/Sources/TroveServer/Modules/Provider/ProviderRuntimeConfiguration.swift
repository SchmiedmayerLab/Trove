//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Explicit deployment configuration, independent of participant connection requests.
struct ProviderRuntimeConfiguration: Sendable {
    struct Registration: Codable, Sendable {
        let configuration: ProviderRegistration
        let approved: Bool
    }

    private struct Document: Decodable {
        let version: Int
        let workerIssuer: String
        let workerClientID: String
        let dormantCredentialRetentionSeconds: Int
        let registrations: [Registration]
        let ouraGlobalScope: ProviderGlobalScopeStore.Configuration?
        let acquisitionFacts: ProviderAcquisitionFacts
        let minimumDispatchIntervalSeconds: Int?
    }

    let worker: ProviderWorkerIdentity
    let acquisitionFacts: ProviderAcquisitionFacts
    let minimumDispatchInterval: TimeInterval
    let dormantCredentialRetention: TimeInterval
    let registrations: [Registration]
    let secrets: ProviderSecretConfiguration
    let ouraGlobalScope: ProviderGlobalScopeStore.Configuration?

    init(bytes: Data, secrets: ProviderSecretConfiguration, revision: String?) throws {
        guard (1...262_144).contains(bytes.count) else { throw ProviderFailure.invalidConfiguration }
        do {
            let document = try JSONDecoder().decode(Document.self, from: bytes)
            guard document.version == 1, (1...128).contains(document.registrations.count),
                  Set(document.registrations.map(\.configuration.id)).count == document.registrations.count,
                  !document.workerIssuer.isEmpty, document.workerIssuer.utf8.count <= 2048,
                  !document.workerClientID.isEmpty, document.workerClientID.utf8.count <= 255,
                  (0...2_592_000).contains(document.dormantCredentialRetentionSeconds),
                  revision.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true else { throw ProviderFailure.invalidConfiguration }
            for registration in document.registrations {
                try registration.configuration.validate()
                if registration.approved { _ = try secrets.applications.secret(for: registration.configuration.id) }
            }
            _ = try document.ouraGlobalScope?.identifier()
            try document.acquisitionFacts.validate()
            let dispatchInterval = document.minimumDispatchIntervalSeconds ?? 5
            guard (1...3600).contains(dispatchInterval) else { throw ProviderFailure.invalidConfiguration }
            self.acquisitionFacts = document.acquisitionFacts
            self.minimumDispatchInterval = TimeInterval(dispatchInterval)
            self.ouraGlobalScope = document.ouraGlobalScope
            self.worker = .init(issuer: document.workerIssuer, clientID: document.workerClientID, applicationRevision: revision)
            self.dormantCredentialRetention = TimeInterval(document.dormantCredentialRetentionSeconds)
            self.registrations = document.registrations
            self.secrets = secrets
        } catch { throw ProviderFailure.invalidConfiguration }
    }

    static func load(environment: [String: String]) throws -> Self? {
        let configurationPath = environment["PROVIDER_CONFIGURATION_FILE"]
        let secretPath = environment["PROVIDER_SECRETS_FILE"]
        guard configurationPath != nil || secretPath != nil else {
            return nil
        }
        guard let configurationPath, let secretPath else { throw ProviderFailure.invalidConfiguration }
        let bytes = try ProviderConfigurationFile.read(path: configurationPath)
        return try .init(bytes: bytes, secrets: .load(file: secretPath), revision: environment["APPLICATION_REVISION"])
    }

    func validateAcquisition(_ client: any ProviderAcquisitionClient) throws {
        for entry in registrations where entry.approved {
            guard entry.configuration.provider == client.provider,
                  entry.configuration.sourceTokens.isSubset(of: client.qualifiedSourceTokens),
                  !entry.configuration.supportsPKCE else { throw ProviderFailure.invalidConfiguration }
        }
    }
}
