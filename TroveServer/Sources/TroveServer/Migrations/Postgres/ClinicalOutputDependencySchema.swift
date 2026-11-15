//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import FluentSQL


enum ClinicalOutputDependencySchema {
    static func create(on database: any Database) async throws {
        try await database.schema("clinical_output_dependencies")
            .field("node_id", .uuid, .required)
            .field("ordinal", .int, .required, .sql(unsafeRaw: "CHECK (ordinal BETWEEN 0 AND 511)"))
            .compositeIdentifier(over: "node_id", "ordinal")
            .field("event_id", .uuid, .required)
            .field("source_id", .uuid, .required)
            .field("target_node_id", .uuid, .required, .sql(unsafeRaw: "CHECK (target_node_id <> node_id)"))
            .field("relation", .string, .required, .sql(unsafeRaw: "CHECK (relation IN ('derivedFrom', 'related'))"))
            .unique(on: "node_id", "target_node_id", "relation", name: "clinical_output_dependency_identity")
            .foreignKey(
                ["node_id", "event_id", "source_id"],
                references: "clinical_event_nodes",
                ["id", "event_id", "source_id"],
                onDelete: .restrict,
                name: "clinical_output_dependency_node_fk"
            )
            .foreignKey(
                ["target_node_id", "event_id", "source_id"],
                references: "clinical_event_nodes",
                ["id", "event_id", "source_id"],
                onDelete: .restrict,
                name: "clinical_output_dependency_target_fk"
            )
            .foreignKey(["node_id", "source_id"], references: "clinical_point_facts", ["node_id", "source_id"], onDelete: .restrict)
            .foreignKey(["target_node_id", "source_id"], references: "clinical_point_facts", ["node_id", "source_id"], onDelete: .restrict)
            .create()
    }
}
