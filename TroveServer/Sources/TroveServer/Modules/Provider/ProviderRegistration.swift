//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveProviderFHIR


/// Operator-approved integration identity. Application secrets are stored separately.
struct ProviderRegistration: Codable, Sendable, Equatable {
    struct Redirect: Codable, Sendable, Equatable {
        let id: String
        let uri: URL
    }

    let id: UUID
    let provider: ConnectedProvider
    let displayName: String
    let controller: String
    let region: String
    let clientID: String
    let redirects: [Redirect]
    let scopes: Set<String>
    let sourceTokens: Set<String>
    let supportsPKCE: Bool

    func validate() throws {
        let supported = Set(ProviderCapabilities.sources(for: provider.converter).filter { $0.conversionSupport == .structured }.map(\.token))
        guard [displayName, controller, region, clientID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 255 }),
              (1...8).contains(redirects.count), Set(redirects.map(\.id)).count == redirects.count,
              (1...64).contains(scopes.count), (1...512).contains(sourceTokens.count), sourceTokens.isSubset(of: supported),
              scopes.union(sourceTokens).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 255 && !$0.contains(" ") }),
              redirects.allSatisfy({ redirect in
                guard let components = URLComponents(url: redirect.uri, resolvingAgainstBaseURL: false) else {
                    return false
                }
                return !redirect.id.isEmpty && redirect.id.utf8.count <= 64 && components.scheme == "https"
                    && components.host != nil && components.user == nil && components.password == nil
                    && components.fragment == nil && components.query == nil
              }) else { throw ProviderFailure.invalidConfiguration }
    }

    func redirect(id: String) throws -> URL {
        guard let redirect = redirects.first(where: { $0.id == id }) else { throw ProviderFailure.invalidLink }
        return redirect.uri
    }
}
