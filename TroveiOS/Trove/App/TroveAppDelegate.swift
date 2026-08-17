//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Grove
import GroveAccount
import GroveKeychainStorage


actor TroveStandard: Standard {}


class TroveAppDelegate: GroveAppDelegate {
    override var configuration: Configuration {
        let keycloak = KeycloakAccountService(
            configuration: KeycloakConfiguration(
                issuer: Config.keycloakIssuer,
                clientID: Config.keycloakClientID,
                redirectURI: Config.keycloakRedirectURI
            )
        )
        return Configuration(standard: TroveStandard()) {
            KeychainStorage()
            TroveAPIModule()
            AccountConfiguration(
                service: keycloak,
                storageProvider: TroveAccountStorage(),
                configuration: [
                    .requires(\.userId),
                    .requires(\.name),
                    .requires(\.genderIdentity),
                    .requires(\.dateOfBirth),
                    .requires(\.region),
                    .requires(\.language),
                    .requires(\.phoneNumber),
                    .supports(\.keycloakAccountConsole)
                ]
            )
            BrowseModel()
            EnrollmentModel()
        }
    }
}
