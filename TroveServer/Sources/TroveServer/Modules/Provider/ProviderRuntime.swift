//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Grove


/// Provider integrations are optional; unavailable credentials never trigger replacement identity or vault keys.
final class ProviderRuntime: Module, Sendable {
    let registrations: ProviderRegistrationService
    let connections: ProviderConnectionService?

    init(registrations: ProviderRegistrationService, connections: ProviderConnectionService?) {
        self.registrations = registrations
        self.connections = connections
    }

    func requireConnections() throws -> ProviderConnectionService {
        guard let connections else { throw ProviderFailure.unavailable }
        return connections
    }
}
