// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import TroveAPIServer


extension Components.Schemas.ProviderRegistration {
    init(_ value: ProviderRegistrationService.Available) throws {
        let provider: ProviderPayload = switch value.provider {
        case .withings: .withings
        case .oura: .oura
        case .googleHealthAPI: .googleHealthApi
        }
        self.init(
            id: value.id.uuidString.lowercased(),
            provider: provider,
            displayName: value.displayName,
            controller: value.controller,
            region: value.region,
            redirects: value.redirects.map { .init(id: $0.id, uri: $0.uri.absoluteString) },
            capabilities: try value.capabilities.map(Components.Schemas.ProviderCollectionCapability.init)
        )
    }
}


extension Components.Schemas.ProviderCollectionCapability {
    init(_ value: ProviderRegistrationService.Capability) throws {
        let effective: EffectiveTimePayload = switch value.effective {
        case .dateTime: .point
        case .period: .interval
        case .dateTimeOrPeriod: .pointOrInterval
        }
        self.init(
            sourceTypeIdentifier: value.sourceTypeIdentifier,
            measurements: try value.profiles.map { profile in
                .init(
                    profile: profile,
                    displayNameEnglish: try CollectionScopePresentation.displayName(
                        profile, german: false, sourceTypeIdentifier: value.sourceTypeIdentifier
                    ),
                    displayNameGerman: try CollectionScopePresentation.displayName(
                        profile, german: true, sourceTypeIdentifier: value.sourceTypeIdentifier
                    )
                )
            },
            effectiveTime: effective
        )
    }
}


extension Components.Schemas.ProviderConnection {
    init(_ value: ProviderConnectionService.Status) {
        let state: StatePayload = switch value.state {
        case .active: .active
        case .disconnected: .disconnected
        case .reauthorizationRequired: .reauthorizationRequired
        }
        self.init(
            id: value.id.uuidString.lowercased(),
            registrationId: value.registrationID.uuidString.lowercased(),
            sourceId: value.sourceID.uuidString.lowercased(),
            state: state,
            generation: value.generation,
            lastAttempt: value.lastAttempt,
            lastSuccessfulFetch: value.lastSuccessfulFetch,
            acceptedThrough: value.acceptedThrough,
            requiresReauthorization: value.requiresReauthorization,
            collectionAttempt: value.collectionAttempt.map(Components.Schemas.ProviderCollectionAttempt.init)
        )
    }
}


extension Components.Schemas.ProviderCollectionAttempt {
    init(_ value: ProviderConnectionService.CollectionAttempt) {
        let outcome: OutcomePayload = switch value.outcome {
        case .scheduled: .scheduled
        case .deferred: .deferred
        case .accepted: .accepted
        case .noCurrentDemand: .noCurrentDemand
        case .transientFailure: .transientFailure
        case .capacityBlocked: .capacityBlocked
        case .sourceBlocked: .sourceBlocked
        case .authorizationChanged: .authorizationChanged
        }
        self.init(sourceTypeIdentifier: value.sourceTypeIdentifier, outcome: outcome, nextAttempt: value.nextAttempt)
    }
}
