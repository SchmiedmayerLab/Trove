//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import AppAuth
import Foundation
import Grove
import GroveAccount
import GroveKeychainStorage
import UIKit


/// GroveAccount ``AccountService`` backed by a Keycloak / OIDC identity provider.
///
/// This module mirrors the public surface of `GroveFirebaseAccount` so it can be lifted into a
/// dedicated Keycloak account-service package later without touching the embedding application.
///
/// ## Wiring
///
/// ```swift
/// AccountConfiguration(
///     service: KeycloakAccountService(
///         configuration: KeycloakConfiguration(
///             issuer: …,
///             clientID: …,
///             redirectURI: …
///         )
///     ),
///     ...
/// )
/// ```
@MainActor
public final class KeycloakAccountService: AccountService {
    private static let supportedKeys = AccountKeyCollection { \.accountId; \.userId; \.keycloakAccountConsole }
    private static let keychainTag = CredentialsTag.genericPassword(forService: "org.troveplatform.app.keycloak.authState")
    private static let keychainUsername = "authState"

    @Dependency(Account.self) private var account
    @Dependency(KeychainStorage.self) private var keychain
    @Dependency(ExternalAccountStorage.self) private var externalStorage

    @IdentityProvider(section: .primary) private var signInView = KeycloakSignInView()

    public let configuration: AccountServiceConfiguration

    /// Static Keycloak realm + client configuration provided by the embedding application.
    public let keycloakConfiguration: KeycloakConfiguration

    private var authState: OIDAuthState?
    private var session: OIDExternalUserAgentSession?

    public init(configuration: KeycloakConfiguration) {
        self.keycloakConfiguration = configuration
        self.configuration = AccountServiceConfiguration(supportedKeys: .exactly(Self.supportedKeys)) {
            UserIdConfiguration.emailAddress
            RequiredAccountKeys { \.userId }
        }
    }

    private static func topViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController
    }

    public func configure() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--reset-authentication-state") {
            authState = nil
            try? clearState()
        }
        #endif

        let stream = externalStorage.updatedDetails
        Task { [weak self] in
            for await update in stream { await self?.applyExternalUpdate(update) }
        }
        Task { await self.restoreSession() }
    }

    // MARK: - AccountService

    public func signIn() async throws { try await authorize(register: false) }
    public func signUp() async throws { try await authorize(register: true) }

    public func logout() async throws {
        // Local-only logout: the sign-in flow uses an ephemeral web session (see `authorize`),
        // so no Keycloak SSO cookie is persisted and there is nothing to clear in the browser.
        authState = nil
        try? clearState()
        account.removeUserDetails()
    }

    public func delete() async throws { throw KeycloakAccountError.deletionUnsupported }

    public func updateAccountDetails(_ modifications: AccountModifications) async throws {
        guard let accountId = account.details?.accountId else { throw KeycloakAccountError.notSignedIn }
        var external = modifications
        external.removeModifications(for: Self.supportedKeys)
        guard !external.isEmpty else {
            return
        }
        try await externalStorage.updateExternalStorage(with: external, for: accountId)
    }

    /// Returns a non-expired access token, refreshing in-flight if needed.
    public func currentAccessToken() async throws -> String {
        guard let state = authState else { throw KeycloakAccountError.notSignedIn }
        let token: String = try await withCheckedThrowingContinuation { continuation in
            state.performAction { token, _, error in
                if let token {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: error ?? KeycloakAccountError.tokenRefreshFailed)
                }
            }
        }
        try? saveState(state)
        return token
    }

    // MARK: - OIDC

    private func authorize(register: Bool) async throws {
        guard let presenter = Self.topViewController() else {
            throw KeycloakAccountError.couldNotStartSession
        }
        let request = OIDAuthorizationRequest(
            configuration: serviceConfiguration(register: register),
            clientId: keycloakConfiguration.clientID,
            scopes: [OIDScopeOpenID, OIDScopeProfile, OIDScopeEmail],
            redirectURL: keycloakConfiguration.redirectURI,
            responseType: OIDResponseTypeCode,
            additionalParameters: nil
        )
        // Use an ephemeral web session so no Keycloak SSO cookie is shared with Safari or
        // persisted between sign-ins. This lets a different account sign in after logout and
        // avoids the iOS "Wants to Use … to Sign In" consent prompt.
        guard let agent = OIDExternalUserAgentIOS(presenting: presenter, prefersEphemeralSession: true) else {
            throw KeycloakAccountError.couldNotStartSession
        }
        let state: OIDAuthState = try await withCheckedThrowingContinuation { continuation in
            session = OIDAuthState.authState(byPresenting: request, externalUserAgent: agent) { state, error in
                if let state {
                    continuation.resume(returning: state)
                } else {
                    continuation.resume(throwing: error ?? KeycloakAccountError.invalidCallback)
                }
            }
        }
        authState = state
        try saveState(state)
        await publishDetails(state: state, isNew: register)
    }

    private func serviceConfiguration(register: Bool) -> OIDServiceConfiguration {
        let issuer = keycloakConfiguration.issuer
        return OIDServiceConfiguration(
            authorizationEndpoint: issuer.appendingPathComponent("protocol/openid-connect/\(register ? "registrations" : "auth")"),
            tokenEndpoint: issuer.appendingPathComponent("protocol/openid-connect/token"),
            issuer: issuer
        )
    }

    // MARK: - Details

    private func restoreSession() async {
        guard let state = try? loadState() else {
            try? clearState()
            return
        }
        authState = state
        do {
            _ = try await currentAccessToken()
            await publishDetails(state: state, isNew: false)
        } catch {
            authState = nil
            try? clearState()
        }
    }

    private func publishDetails(state: OIDAuthState, isNew: Bool, external: AccountDetails? = nil) async {
        guard var details = identityDetails(state: state, isNew: isNew) else {
            return
        }
        let extra: AccountDetails
        if let external {
            extra = external
        } else {
            var keys = account.configuration.keys
            keys.removeAll(Self.supportedKeys)
            extra = await externalStorage.retrieveExternalStorage(for: details.accountId, keys._keys)
        }
        details.add(contentsOf: extra)
        account.supplyUserDetails(details)
    }

    private func applyExternalUpdate(_ update: ExternalAccountStorage.ExternallyStoredDetails) async {
        guard let state = authState,
              let identity = identityDetails(state: state, isNew: false),
              identity.accountId == update.accountId else { return }
        await publishDetails(state: state, isNew: false, external: update.details)
    }

    private func identityDetails(state: OIDAuthState, isNew: Bool) -> AccountDetails? {
        guard let idToken = state.lastTokenResponse?.idToken,
              let parsed = OIDIDToken(idTokenString: idToken) else { return nil }
        var details = AccountDetails()
        details.accountId = parsed.subject
        details.userId = (parsed.claims["email"] as? String)
            ?? (parsed.claims["preferred_username"] as? String)
            ?? parsed.subject
        details.isNewUser = isNew
        details.keycloakAccountConsole = "managed-by-keycloak"
        return details
    }

    // MARK: - Keychain

    private func loadState() throws -> OIDAuthState? {
        guard let stored = try keychain.retrieveCredentials(withUsername: Self.keychainUsername, for: Self.keychainTag),
              let data = Data(base64Encoded: stored.password) else { return nil }
        return try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data)
    }

    private func saveState(_ state: OIDAuthState) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
        try keychain.store(
            Credentials(username: Self.keychainUsername, password: data.base64EncodedString()),
            for: Self.keychainTag
        )
    }

    private func clearState() throws {
        try keychain.deleteCredentials(withUsername: Self.keychainUsername, for: Self.keychainTag)
    }
}
