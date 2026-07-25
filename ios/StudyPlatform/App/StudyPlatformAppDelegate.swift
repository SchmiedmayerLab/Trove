//
// This source file is part of the StudyPlatform-iOS open source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Spezi
import SpeziAccount
import SpeziKeychainStorage

class StudyPlatformAppDelegate: SpeziAppDelegate {
    override var configuration: Configuration {
        let keycloak = KeycloakAccountService(
            configuration: KeycloakConfiguration(
                issuer: Config.keycloakIssuer,
                clientID: Config.keycloakClientID,
                redirectURI: Config.keycloakRedirectURI
            )
        )
        return Configuration(standard: StudyPlatformStandard()) {
            KeychainStorage()
            StudyPlatformAPIModule()
            AccountConfiguration(
                service: keycloak,
                storageProvider: StudyPlatformAccountStorage(),
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

actor StudyPlatformStandard: Standard {}
