//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SQLKit


/// Immutable output lineage. Each endpoint retains its own study grants.
struct ClinicalOutputDependencyStore: Sendable {
    let sql: any SQLDatabase

    static func validate(_ event: ValidatedExchangeEvent) throws {
        let outputs = Set(event.outputs.map(\.fullURL))
        guard Set(event.nodes.map(\.fullURL)).count == event.nodes.count else { throw FHIRValidationClient.invalid }
        let nodes = Dictionary(uniqueKeysWithValues: event.nodes.map { ($0.fullURL, $0.resourceType) })
        guard event.outputDependencies.count <= 512,
              Set(event.outputDependencies).count == event.outputDependencies.count,
              event.outputDependencies.allSatisfy({ dependency in
                  outputs.contains(dependency.outputFullURL) && outputs.contains(dependency.targetFullURL)
                      && dependency.outputFullURL != dependency.targetFullURL
                      && nodes[dependency.outputFullURL] == (dependency.relation == .derivedFrom ? "Observation" : "DocumentReference")
                      && ["Observation", "DocumentReference"].contains(nodes[dependency.targetFullURL] ?? "")
              }) else { throw FHIRValidationClient.invalid }
    }

    func insert(_ event: ValidatedExchangeEvent, nodeIDs: [String: UUID], receipt: ClinicalEventReceipt) async throws {
        for (ordinal, dependency) in event.outputDependencies.enumerated() {
            guard let nodeID = nodeIDs[dependency.outputFullURL], let targetID = nodeIDs[dependency.targetFullURL] else {
                throw ServerError.unexpectedError
            }
            try await sql.raw("""
                INSERT INTO clinical_output_dependencies (node_id, ordinal, event_id, source_id, target_node_id, relation)
                VALUES (\(bind: nodeID), \(bind: ordinal), \(bind: receipt.eventID), \(bind: receipt.sourceID),
                    \(bind: targetID), \(bind: dependency.relation.rawValue))
                """)
                .run()
        }
    }
}
