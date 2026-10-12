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


/// Collects deployment-owned identifiers, including reference and entry-key identifiers,
/// only from bytes already accepted by the complete graph validator.
struct FHIRDeploymentIdentifiers: Decodable, Sendable {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    var systems: [GroveIdentifierRole: Set<String>] = [:]

    init(systems: [GroveIdentifierRole: Set<String>]) {
        self.systems = systems
    }

    init(from decoder: any Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            while !array.isAtEnd { merge(try array.decode(Self.self)) }
        } else if let object = try? decoder.container(keyedBy: Key.self) {
            for key in object.allKeys {
                if key.stringValue == "identifier" || key.stringValue == "valueIdentifier" {
                    let identifiers: [Identifier]
                    if var array = try? object.nestedUnkeyedContainer(forKey: key) {
                        var values: [Identifier] = []
                        while !array.isAtEnd { values.append(try array.decode(Identifier.self)) }
                        identifiers = values
                    } else {
                        identifiers = [try object.decode(Identifier.self, forKey: key)]
                    }
                    for identifier in identifiers where identifier.type?.coding?.contains(where: {
                        $0.system == Canonicals.identifierRoleCodeSystem
                    }) == true {
                        let roled = try RoledIdentifier(identifier)
                        systems[roled.role, default: []].insert(roled.identifier.system.rawValue)
                    }
                } else {
                    merge(try object.decode(Self.self, forKey: key))
                }
            }
        }
    }

    static func system(for role: GroveIdentifierRole, in expected: DeploymentIdentifierSystems) -> IdentifierSystem {
        switch role {
        case .sourceRecord: expected.sourceRecord
        case .sourceOutput: expected.sourceOutput
        case .writerRecord: expected.writerRecord
        case .sourceArtifact: expected.sourceArtifact
        case .sourceContext: expected.sourceContext
        case .recordingDevice: expected.recordingDevice
        case .deviceSnapshot: expected.deviceSnapshot
        case .event: expected.event
        case .entryNode: expected.entryNode
        }
    }

    private mutating func merge(_ other: Self) {
        for (role, values) in other.systems { systems[role, default: []].formUnion(values) }
    }

    func matches(_ expected: DeploymentIdentifierSystems) -> Bool {
        guard systems[.event] == [expected.event.rawValue] else {
            return false
        }
        return systems.allSatisfy { role, values in
            values == [Self.system(for: role, in: expected).rawValue]
        }
    }
}
