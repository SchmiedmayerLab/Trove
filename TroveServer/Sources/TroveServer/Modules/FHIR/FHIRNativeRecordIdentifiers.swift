//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import ModelsR4


/// Supported HealthKit native identifier evidence after complete IG validation.
/// The source owner separately checks the registered store namespace at admission.
enum FHIRNativeRecordIdentifiers {
    struct Output {
        var roles: [RoledIdentifier] = []
        var native: [ValidatedExchangeEvent.Identifier] = []
        var sync: [ValidatedExchangeEvent.Identifier] = []
    }

    /// An output's Grove roles, its native UUID and its readable sync identifier, each at most once. `extensions` are the
    /// output's own, which must state the writer-record version a sync identifier travels beside.
    static func output(_ identifiers: [Identifier], extensions: [Extension]) throws -> Output {
        var output = Output()
        var sync: [Identifier] = []
        for identifier in identifiers {
            if identifier.type?.coding?.contains(where: { $0.system == Canonicals.identifierRoleCodeSystem }) == true {
                output.roles.append(try RoledIdentifier(identifier))
            } else if FHIRSyncRecordIdentifier.isTyped(identifier) {
                sync.append(identifier)
            } else {
                output.native.append(try nativeIdentifier(identifier))
            }
        }
        guard output.native.count <= 1, sync.count <= 1 else { throw FHIRValidationClient.invalid }
        output.sync = try sync.map { try FHIRSyncRecordIdentifier.validated($0, roles: output.roles, extensions: extensions) }
        return output
    }

    static func retraction(in resources: [String: ResourceProxy]) throws -> [ValidatedExchangeEvent.Identifier] {
        var values: Set<ValidatedExchangeEvent.Identifier> = []
        for resource in resources.values {
            guard case .provenance(let provenance) = resource else { continue }
            for target in provenance.target {
                let extensions = (target.extension ?? []).filter { $0.url == Canonicals.retractionTargetNativeIdentifier }
                guard extensions.count <= 1 else { throw FHIRValidationClient.invalid }
                for value in extensions {
                    guard case .identifier(let identifier)? = value.value else { throw FHIRValidationClient.invalid }
                    values.insert(try nativeIdentifier(identifier))
                }
            }
        }
        guard values.count <= 1 else { throw FHIRValidationClient.invalid }
        return Array(values)
    }

    private static func nativeIdentifier(_ identifier: Identifier) throws -> ValidatedExchangeEvent.Identifier {
        // The exporter states only the original UUID and its store namespace. Do not
        // silently accept additional references, validity periods or alternate meanings.
        guard identifier.type == nil, identifier.use == nil, identifier.period == nil, identifier.assigner == nil,
              identifier.extension?.isEmpty != false,
              let system = identifier.system?.value?.url.absoluteString, (1...512).contains(system.utf8.count),
              let value = identifier.value?.value?.string, let uuid = UUID(uuidString: value), value == uuid.uuidString.lowercased() else {
            throw FHIRValidationClient.invalid
        }
        _ = try BusinessIdentifier(identifier)
        return .init(system: system, value: value)
    }
}
