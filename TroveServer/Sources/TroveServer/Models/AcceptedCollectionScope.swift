//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPITypes


/// A nil start denotes exact stored consent acceptance; historical starts are retained literal instants.
struct ResolvedCollectionWindow: Codable, Sendable, Hashable {
    let start: Date?
    let end: Date?
}


/// Stored atomically with immutable consent, bound to the publication by that consent's presentation proof.
struct AcceptedCollectionScope: Codable, Sendable, Hashable {
    struct Requirement: Codable, Sendable, Hashable {
        let profile: String
        let sourceKind: SourceKind
        let providerRegistrationID: UUID?
        let sourceTypeIdentifier: String?
        let timeBasis: CollectionTimeBasis?
        let window: ResolvedCollectionWindow
        let includeWorkoutRoutes: Bool

        init(
            profile: String,
            sourceKind: SourceKind,
            window: ResolvedCollectionWindow,
            includeWorkoutRoutes: Bool,
            providerRegistrationID: UUID? = nil,
            sourceTypeIdentifier: String? = nil,
            timeBasis: CollectionTimeBasis? = nil
        ) {
            self.profile = profile
            self.sourceKind = sourceKind
            self.providerRegistrationID = providerRegistrationID
            self.sourceTypeIdentifier = sourceTypeIdentifier
            self.timeBasis = timeBasis
            self.window = window
            self.includeWorkoutRoutes = includeWorkoutRoutes
        }
    }

    let requirements: [Requirement]

    init(requirements: [CollectionRequirement], acceptedAt: Date) throws {
        self.requirements = try requirements.map {
            .init(
                profile: $0.profile,
                sourceKind: $0.sourceKind,
                window: try $0.measurementWindow?.resolve(at: acceptedAt) ?? .init(start: nil, end: nil),
                includeWorkoutRoutes: $0.includeWorkoutRoutes,
                providerRegistrationID: $0.providerRegistrationID,
                sourceTypeIdentifier: $0.sourceTypeIdentifier,
                timeBasis: $0.timeBasis
            )
        }
    }
}
