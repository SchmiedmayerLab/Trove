//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SQLKit


/// Direct questionnaire derivations, without a mutable readiness cache or cross-source resolver.
struct ClinicalGraphStore: Sendable {
    let sql: any SQLDatabase

    static func validate(_ event: ValidatedExchangeEvent) throws {
        let contexts = event.questionnaireContexts
        let contextURLs = Set(contexts.map(\.fullURL))
        let outputURLs = Set(event.outputs.map(\.fullURL))
        let includedTargets = event.derivations.reduce(into: Set<String>()) { result, derivation in
            switch derivation.target {
            case .local(let target): result.insert(target)
            case .logical(let identifier): result.formUnion(contexts.filter { $0.identifier == identifier }.map(\.fullURL))
            }
        }
        guard contexts.count <= 512, event.derivations.count <= 512, contextURLs.count == contexts.count,
              contextURLs == Set(event.nodes.filter { $0.resourceType == "QuestionnaireResponse" }.map(\.fullURL)),
              contextURLs == includedTargets, contexts.allSatisfy({ bounded($0.identifier) }),
              event.derivations.allSatisfy({ dependency in
                  guard outputURLs.contains(dependency.outputFullURL) else {
                      return false
                  }
                  switch dependency.target {
                  case .local(let target): return contextURLs.contains(target)
                  case .logical(let identity): return bounded(identity)
                  }
              }) else { throw ServerError.badRequest("Unsupported or unbounded clinical derivation graph") }
    }

    private static func bounded(_ identifier: ValidatedExchangeEvent.Identifier) -> Bool {
        (1...512).contains(identifier.system.utf8.count) && (1...512).contains(identifier.value.utf8.count)
    }

    func insert(_ event: ValidatedExchangeEvent, nodeIDs: [String: UUID], receipt: ClinicalEventReceipt) async throws {
        for context in event.questionnaireContexts {
            guard let nodeID = nodeIDs[context.fullURL] else { throw ServerError.unexpectedError }
            try await sql.raw("""
                INSERT INTO clinical_questionnaire_contexts (node_id, event_id, source_id, identifier_system, identifier_value)
                VALUES (\(bind: nodeID), \(bind: receipt.eventID), \(bind: receipt.sourceID),
                    \(bind: context.identifier.system), \(bind: context.identifier.value))
                """)
                .run()
        }
        for (ordinal, dependency) in event.derivations.enumerated() {
            guard let nodeID = nodeIDs[dependency.outputFullURL] else { throw ServerError.unexpectedError }
            let targetID: UUID?
            let identifier: ValidatedExchangeEvent.Identifier?
            switch dependency.target {
            case .local(let fullURL):
                guard let id = nodeIDs[fullURL] else { throw ServerError.unexpectedError }
                targetID = id
                identifier = nil
            case .logical(let identity):
                targetID = nil
                identifier = identity
            }
            try await sql.raw("""
                INSERT INTO clinical_point_derivations (node_id, ordinal, event_id, source_id, target_node_id, identifier_system, identifier_value)
                VALUES (\(bind: nodeID), \(bind: ordinal), \(bind: receipt.eventID), \(bind: receipt.sourceID),
                    \(bind: targetID), \(bind: identifier?.system), \(bind: identifier?.value))
                """)
                .run()
        }
    }
}


extension ClinicalGraphStore {
    /// For a point node `n` and exact study grant `g`. Identity resolution never supplies permission.
    static var disclosurePredicate: SQLQueryString {
        let match: SQLQueryString = """
            context.source_id = dependency.source_id AND
                (context.node_id = dependency.target_node_id OR
                    (dependency.target_node_id IS NULL AND context.identifier_system = dependency.identifier_system
                        AND context.identifier_value = dependency.identifier_value))
            """
        return """
            NOT EXISTS (
                SELECT 1 FROM clinical_point_derivations dependency WHERE dependency.node_id = n.id AND (
                    (SELECT COUNT(*) FROM clinical_questionnaire_contexts context WHERE \(match)) <> 1
                    OR NOT EXISTS (
                        SELECT 1 FROM clinical_questionnaire_contexts context
                        JOIN clinical_point_derivations direct ON direct.target_node_id = context.node_id OR
                            (direct.target_node_id IS NULL AND direct.event_id = context.event_id
                                AND direct.identifier_system = context.identifier_system AND direct.identifier_value = context.identifier_value)
                        JOIN study_data_grants purpose ON purpose.node_id = direct.node_id
                        JOIN clinical_point_facts parent ON parent.node_id = purpose.node_id
                        WHERE \(match) AND purpose.enrollment_id = g.enrollment_id AND purpose.source_id = g.source_id
                            AND NOT EXISTS (SELECT 1 FROM clinical_output_retractions removed
                                WHERE removed.output_binding_id = parent.output_binding_id)
                    )
                )
            )
            """
    }
}
