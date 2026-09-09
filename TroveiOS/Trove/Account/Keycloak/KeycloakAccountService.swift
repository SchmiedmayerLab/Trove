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

    @IdentityProvider private var signInView: KeycloakSignInView

    public let configuration: AccountServiceConfiguration

    /// Static Keycloak realm + client configuration provided by the embedding application.
    public let keycloakConfiguration: KeycloakConfiguration

    private var authState: OIDAuthState?
    private var session: OIDExternalUserAgentSession?
    private let lifecycle = KeycloakSessionLifecycle()

    /// Observed through the lifecycle object; refreshes do not change the session identity.
    var sessionSnapshot: KeycloakSessionSnapshot? { lifecycle.snapshot }

    public init(configuration: KeycloakConfiguration) {
        let signInView = KeycloakSignInView()
        self._signInView = IdentityProvider(wrappedValue: signInView, section: .primary)
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

    /// Grove's account button presents thrown errors directly, outside the global error handler.
    static func sanitizedAuthorizationError(_ error: any Error) -> any Error {
        if Task.isCancelled || error is CancellationError {
            return CancellationError()
        }
        if let error = error as? KeycloakAccountError {
            return error
        }
        let providerError = error as NSError
        if providerError.domain == OIDGeneralErrorDomain,
           [OIDErrorCode.userCanceledAuthorizationFlow.rawValue, OIDErrorCode.programCanceledAuthorizationFlow.rawValue]
            .contains(providerError.code) {
            return CancellationError()
        }
        return KeycloakAccountError.authenticationFailed
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
        let generation = lifecycle.generation
        Task { await self.restoreSession(generation: generation) }
    }

    // MARK: - AccountService

    public func signIn() async throws { try await authorize(register: false) }
    public func signUp() async throws { try await authorize(register: true) }

    public func logout() async throws {
        // Local-only logout: the sign-in flow uses an ephemeral web session (see `authorize`),
        // so no Keycloak SSO cookie is persisted and there is nothing to clear in the browser.
        invalidateSession()
        account.removeUserDetails()
        try clearState()
    }

    public func delete() async throws { throw KeycloakAccountError.deletionUnsupported }

    public func updateAccountDetails(_ modifications: AccountModifications) async throws {
        guard let snapshot = sessionSnapshot else { throw KeycloakAccountError.notSignedIn }
        try validateSession(snapshot)
        var external = modifications
        external.removeModifications(for: Self.supportedKeys)
        guard !external.isEmpty else {
            return
        }
        try await lifecycle.perform(for: snapshot.generation) {
            try await KeycloakSessionScope.$expected.withValue(snapshot) {
                try await externalStorage.updateExternalStorage(with: external, for: snapshot.subject)
            }
        }
        try validateSession(snapshot)
    }

    /// Returns a non-expired access token, refreshing in-flight if needed.
    public func currentAccessToken() async throws -> String {
        guard let snapshot = sessionSnapshot else { throw KeycloakAccountError.notSignedIn }
        return try await token(for: snapshot)
    }

    func validateSession(_ snapshot: KeycloakSessionSnapshot) throws {
        try lifecycle.validate(snapshot)
        guard let state = authState, identityDetails(state: state, isNew: false)?.accountId == snapshot.subject else {
            throw CancellationError()
        }
    }

    func token(for snapshot: KeycloakSessionSnapshot) async throws -> String {
        try validateSession(snapshot)
        guard let state = authState else { throw KeycloakAccountError.notSignedIn }
        let token: String = try await lifecycle.perform(for: snapshot.generation) {
            try await KeycloakTokenRequest.value { complete in
                state.performAction { token, _, error in
                    if let token {
                        complete(.success(token))
                    } else {
                        complete(.failure(error ?? KeycloakAccountError.tokenRefreshFailed))
                    }
                }
            }
        }
        try validateSession(snapshot)
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
        invalidateSession()
        account.removeUserDetails()
        let generation = lifecycle.generation
        do {
            try clearState()
            let state: OIDAuthState = try await lifecycle.perform(for: generation) {
                try await withCheckedThrowingContinuation { continuation in
                    session = OIDAuthState.authState(byPresenting: request, externalUserAgent: agent) { state, error in
                        if let state {
                            continuation.resume(returning: state)
                        } else {
                            continuation.resume(throwing: error ?? KeycloakAccountError.invalidCallback)
                        }
                    }
                }
            }
            session = nil
            try install(state, generation: generation)
            try saveState(state)
            try await publishDetails(state: state, isNew: register, generation: generation)
        } catch {
            clearFailedSession(generation: generation)
            throw Self.sanitizedAuthorizationError(error)
        }
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

    private func restoreSession(generation: UUID) async {
        guard lifecycle.generation == generation else {
            return
        }
        guard let state = try? loadState() else {
            try? clearState()
            return
        }
        do {
            try install(state, generation: generation)
            _ = try await currentAccessToken()
            try await publishDetails(state: state, isNew: false, generation: generation)
        } catch {
            clearFailedSession(generation: generation)
        }
    }

    private func publishDetails(state: OIDAuthState, isNew: Bool, generation: UUID) async throws {
        try lifecycle.requireGeneration(generation)
        guard var details = identityDetails(state: state, isNew: isNew) else {
            return
        }
        guard let snapshot = sessionSnapshot else { throw CancellationError() }
        try validateSession(snapshot)
        var keys = account.configuration.keys
        keys.removeAll(Self.supportedKeys)
        let extra = try await lifecycle.perform(for: generation) {
            await KeycloakSessionScope.$expected.withValue(snapshot) {
                await externalStorage.retrieveExternalStorage(for: details.accountId, keys._keys)
            }
        }
        try lifecycle.requireGeneration(generation)
        try Task.checkCancellation()
        details.add(contentsOf: extra)
        account.supplyUserDetails(details)
    }

    private func applyExternalUpdate(_ update: ExternalAccountStorage.ExternallyStoredDetails) async {
        guard let state = authState,
              let identity = identityDetails(state: state, isNew: false),
              identity.accountId == update.accountId else { return }
        // Buffered notifications carry no session generation. Re-read the current session's
        // storage instead of publishing a payload from an earlier login of the same account.
        try? await publishDetails(state: state, isNew: false, generation: lifecycle.generation)
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

    private func install(_ state: OIDAuthState, generation: UUID) throws {
        try lifecycle.requireGeneration(generation)
        try KeycloakAuthStateBinding.validate(state, configuration: keycloakConfiguration)
        guard let identity = identityDetails(state: state, isNew: false) else {
            throw KeycloakAccountError.missingIDToken
        }
        authState = state
        try lifecycle.install(subject: identity.accountId, issuer: keycloakConfiguration.issuer, for: generation)
    }

    private func invalidateSession() {
        lifecycle.invalidate()
        authState = nil
        let previous = session
        session = nil
        previous?.cancel()
    }

    private func clearFailedSession(generation: UUID) {
        guard lifecycle.generation == generation else {
            return
        }
        invalidateSession()
        account.removeUserDetails()
        try? clearState()
    }

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
