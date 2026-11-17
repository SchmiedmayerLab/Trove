//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract


/// Persisted before dispatch. A restart does not replace a prior page's converter or host facts.
struct ProviderAcquisitionFacts: Codable, Sendable {
    let applicationName: String
    let bundleIdentifier: String
    let version: String
    let build: String?
    let operatingSystemName: String?
    let operatingSystemVersion: String
    let operatingSystemBuild: String?
    let productType: String?
    let model: String?
    let manufacturer: String?

    init(application: ApplicationDevice, host: HostDevice) {
        applicationName = application.name
        bundleIdentifier = application.bundleIdentifier
        version = application.version
        build = application.build
        operatingSystemName = host.operatingSystemName
        operatingSystemVersion = host.operatingSystemVersion
        operatingSystemBuild = host.operatingSystemBuild
        productType = host.productType
        model = host.model
        manufacturer = host.manufacturer
    }

    /// The participant identity scope this worker mints under; it must match the participant app's recovered scope.
    static func identityScope(source: SourceBinding, identity: SourceIdentityKeyStore.Recovered) throws -> OpaqueIdentityScope {
        try .init(
            root: IdentifierSystem(source.identifierRoot),
            keyID: source.keyID.uuidString.lowercased(),
            epoch: source.keyEpoch,
            key: identity.key
        )
    }

    func validate() throws {
        let required = [applicationName, bundleIdentifier, version, operatingSystemVersion]
        let optional = [build, operatingSystemName, operatingSystemBuild, productType, model, manufacturer].compactMap { $0 }
        guard (required + optional).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }),
              try ProviderSQL.encode(self, maximumBytes: 16_384).utf8.count <= 16_384 else {
            throw ProviderFailure.invalidConfiguration
        }
    }

    func producer(source: SourceBinding, identity: SourceIdentityKeyStore.Recovered) throws -> ExchangeProducer {
        try .init(
            identityScope: Self.identityScope(source: source, identity: identity),
            subject: .logical(.init(system: IdentifierSystem(source.participantIdentifierSystem), value: source.participantIdentifierValue)),
            application: .init(name: applicationName, bundleIdentifier: bundleIdentifier, version: version, build: build),
            host: .init(
                operatingSystemName: operatingSystemName,
                operatingSystemVersion: operatingSystemVersion,
                operatingSystemBuild: operatingSystemBuild,
                productType: productType,
                model: model,
                manufacturer: manufacturer
            )
        )
    }
}
