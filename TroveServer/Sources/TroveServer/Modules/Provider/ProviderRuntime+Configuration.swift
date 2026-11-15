//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import TroveAPITypes
import Vapor


extension ProviderRuntime {
    // Keep trusted startup dependencies explicit; none are supplied through participant requests.
    // swiftlint:disable:next function_parameter_count
    static func configured(
        application: Application,
        configuration: ProviderRuntimeConfiguration?,
        sourceKeyring: SourceIdentityKeyring,
        authorization: AuthorizationService,
        studies: StudyRepository,
        limits: EventSubmissionLimits.Configuration,
        validator: FHIRValidationClient
    ) async throws -> ProviderRuntime {
        let database = application.db(.psql)
        guard let configuration else {
            let registrations = ProviderRegistrationService(
                database: database, clients: [], registrationIDs: [], authorization: authorization, studies: studies
            )
            return .init(registrations: registrations, connections: nil)
        }
        let transport = try ProviderHTTPTransport(application: application)
        let client = WithingsMeasurementClient(transport: transport, limits: limits)
        let registrations = ProviderRegistrationService(
            database: database,
            clients: [client],
            registrationIDs: Set(configuration.registrations.filter(\.approved).map(\.configuration.id)),
            authorization: authorization,
            studies: studies
        )
        try configuration.validateAcquisition(client)
        try await store(configuration, on: database)
        let credentialClient = ProviderAuthorizationRouter(transport: transport, secrets: configuration.secrets.applications)
        let worker = ProviderIngestionService(
            database: database,
            validator: validator,
            credentialService: .init(database: database, vault: configuration.secrets.vault, authorization: credentialClient),
            keyring: sourceKeyring,
            worker: configuration.worker,
            facts: configuration.acquisitionFacts,
            limits: limits,
            client: client,
            dormantRetention: configuration.dormantCredentialRetention
        )
        let service = workerService(
            configuration, registrationIDs: registrations.registrationIDs, workers: [client.provider: worker], on: database
        )
        application.lifecycle.use(ProviderWorkerLifecycle(loop: .init(service: service)))
        return try .init(
            registrations: registrations,
            connections: .init(
                database: database,
                vault: configuration.secrets.vault,
                sourceKeyring: sourceKeyring,
                authorization: credentialClient,
                dormantRetention: configuration.dormantCredentialRetention
            )
        )
    }

    /// Retains the deployment's global scope and registrations under the worker's audit identity.
    private static func store(_ configuration: ProviderRuntimeConfiguration, on database: any Database) async throws {
        let audit = AuditEvent.Context(
            actor: .init(issuer: configuration.worker.issuer, subject: configuration.worker.clientID),
            executingClientID: configuration.worker.clientID,
            applicationRevision: configuration.worker.applicationRevision
        )
        if let scope = configuration.ouraGlobalScope {
            try await ProviderGlobalScopeStore.configure(scope, on: database)
        }
        for entry in configuration.registrations {
            try await ProviderRegistrationStore(database: database).configure(entry.configuration, approved: entry.approved, audit: audit)
        }
    }

    private static func workerService(
        _ configuration: ProviderRuntimeConfiguration,
        registrationIDs: Set<UUID>,
        workers: [ConnectedProvider: ProviderIngestionService],
        on database: any Database
    ) -> ProviderWorkerService {
        ProviderWorkerService(
            store: .init(
                database: database,
                registrationIDs: registrationIDs,
                minimumDispatchInterval: configuration.minimumDispatchInterval
            ),
            workers: workers,
            retirement: .init(
                database: database,
                registrationIDs: Set(configuration.registrations.map(\.configuration.id)),
                worker: configuration.worker,
                retention: configuration.dormantCredentialRetention
            )
        )
    }
}
