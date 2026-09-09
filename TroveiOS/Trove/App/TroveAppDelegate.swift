//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Grove
import GroveAccount
@_spi(Experimental) import GroveHealthKit
import GroveKeychainStorage
import HealthKit
import UIKit


actor TroveStandard: Standard {}


class TroveAppDelegate: GroveAppDelegate {
    private let healthKit = GroveHealthKit.HealthKit()
    private let healthData = HealthDataModel()
    private var healthDataRuntime: HealthDataRuntime?

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
            healthKit
            healthData
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
            ConsentModel()
        }
    }

    func application(
        _ application: UIApplication,
        // UIApplicationDelegate defines the optional dictionary.
        // swiftlint:disable:next discouraged_optional_collection
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else {
            return true
        }
        let store = healthKit.healthStore
        let runtime = HealthDataRuntime(model: healthData) { update in
            store.startBackgroundObservation(for: [HKQuantityType(.heartRate)], updateHandler: { _ in await update() }) {
                let lifetime = AsyncStream<Void>.makeStream()
                defer { lifetime.continuation.finish() }
                for await _ in lifetime.stream { }
            }
        }
        healthDataRuntime = runtime
        runtime.start()
        return true
    }
}
