//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveFHIRContract
import GroveSensorKitFHIR
import ModelsR4


/// Actual adapter evidence from a fully validated output, independent of a request's claimed source token.
struct FHIRSourceTypeEvidence {
    let repository: SourceRepositoryKind
    let identifier: String

    static func extract(_ extensions: [Extension]) throws -> Self? {
        let healthKit = try code(extensions, url: Canonicals.healthKitSourceTypeExtension)
        let sensorKit = try code(extensions, url: SensorKitContract.sourceTypeExtensionURI)
        let provider = try code(extensions, url: Canonicals.providerExtension)
        let providerType = try code(extensions, url: Canonicals.providerSourceTypeExtension)
        guard [healthKit, sensorKit, providerType].compactMap({ $0 }).count <= 1,
              (provider == nil) == (providerType == nil) else { throw FHIRValidationClient.invalid }
        if let healthKit {
            return .init(repository: .healthKit, identifier: healthKit)
        }
        if let sensorKit {
            guard let source = SensorKitCatalog.current.entry(sourceTypeCode: sensorKit) else { throw FHIRValidationClient.invalid }
            return .init(repository: .sensorKit, identifier: source.sourceToken)
        }
        if let provider, let providerType {
            guard let kind = ConnectedProvider(rawValue: provider), providerType.hasPrefix(provider + "/") else {
                throw FHIRValidationClient.invalid
            }
            let token = String(providerType.dropFirst(provider.utf8.count + 1))
            guard !token.isEmpty else { throw FHIRValidationClient.invalid }
            return .init(repository: kind.repositoryKind, identifier: token)
        }
        return nil
    }

    private static func code(_ extensions: [Extension], url: FHIRPrimitive<FHIRURI>) throws -> String? {
        let values = extensions.filter { $0.url == url }
        guard values.count <= 1 else { throw FHIRValidationClient.invalid }
        guard let value = values.first else {
            return nil
        }
        guard value.extension?.isEmpty != false, case .code(let code)? = value.value,
              let text = code.value?.string, (1...512).contains(text.utf8.count) else { throw FHIRValidationClient.invalid }
        return text
    }
}


extension SensorKitContract {
    /// The SensorKit source-type extension URL in the form FHIR extensions carry.
    static let sourceTypeExtensionURI = FHIRPrimitive(FHIRURI(stringLiteral: sourceTypeExtension))
}
