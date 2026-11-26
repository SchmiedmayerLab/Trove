//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import PostgresNIO
import SQLKit
import Synchronization
import Testing
import TroveAPITypes
@testable import TroveServer
import VaporTesting


/// Draft validation reads provider registrations without row locks; publication keeps them locked until it commits.
///
/// Row locks exist only in PostgreSQL, so these cases run in the real-store lane.
struct RouteEvaluationLockTests {
    /// Opens once and lets every waiter continue.
    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            opened = true
            for waiter in waiters {
                waiter.resume()
            }
            waiters = []
        }

        func wait() async {
            guard !opened else {
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// How the concurrent registration update ended.
    private enum Update: Equatable, Sendable {
        case committed
        case lockTimeout
        case failed
    }

    private final class Outcome: Sendable {
        let value = Mutex<Update?>(nil)
    }

    private static func service(on app: Application, registrationID: UUID) -> ProviderRegistrationService {
        .init(
            database: app.db,
            clients: [WithingsMeasurementClient(transport: .init { _, _, _, _ in throw ProviderFailure.unavailable }, limits: .standard)],
            registrationIDs: [registrationID],
            authorization: app.grove[AuthorizationService.self],
            studies: app.grove[StudyRepository.self]
        )
    }

    /// How a registration update on another connection ends while a transaction holds the route evaluation.
    private static func update(whileEvaluatingWith lock: Bool) async throws -> Update? {
        let completed = Outcome()
        try await TestApp.withApp { app, _ in
            let registration = try ProviderFixture.registration()
            try await ProviderRegistrationStore(database: app.db).configure(
                registration, approved: true, audit: ClinicalEventStoreTests.researcher.auditContext
            )
            let service = Self.service(on: app, registrationID: registration.id)
            let requirement = CollectionRequirement(
                profile: CollectionObservationProfile.bodyWeight.rawValue,
                sourceKind: .serverWorker,
                providerRegistrationID: registration.id,
                sourceTypeIdentifier: "getmeas:1"
            )
            let evaluated = Gate()
            let release = Gate()
            let holder = Task {
                do {
                    try await app.db.transaction { transaction in
                        let routes = try await service.routes(for: [requirement], lock: lock, on: transaction)
                        #expect(routes.map(\.available) == [true])
                        await evaluated.open()
                        await release.wait()
                    }
                } catch {
                    // Release the waiting test instead of leaving it blocked; the holder reports the error.
                    await evaluated.open()
                    throw error
                }
            }
            await evaluated.wait()
            let result = await Self.updateRegistration(registration.id, on: app.db)
            completed.value.withLock { $0 = result }
            await release.open()
            try await holder.value
        }
        return completed.value.withLock { $0 }
    }

    /// Updates the registration row on another connection, waiting at most 500 ms for a row lock.
    private static func updateRegistration(_ id: UUID, on database: any Database) async -> Update {
        do {
            try await database.transaction { transaction in
                guard let sql = transaction as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
                try await sql.raw("SET LOCAL lock_timeout = '500ms'").run()
                try await sql.raw("UPDATE provider_registrations SET generation = generation WHERE id = \(bind: id)").run()
            }
            return .committed
        } catch {
            return (error as? PSQLError)?.serverInfo?[.sqlState] == "55P03" ? .lockTimeout : .failed
        }
    }

    @Test(.enabled(if: Environment.get("TROVE_TEST_POSTGRES_PORT") != nil, "Row locks require the isolated PostgreSQL store"))
    func validationDoesNotBlockARegistrationUpdate() async throws {
        #expect(try await Self.update(whileEvaluatingWith: false) == .committed)
    }

    @Test(.enabled(if: Environment.get("TROVE_TEST_POSTGRES_PORT") != nil, "Row locks require the isolated PostgreSQL store"))
    func publicationKeepsTheRegistrationLockedUntilItCommits() async throws {
        #expect(try await Self.update(whileEvaluatingWith: true) == .lockTimeout)
    }
}
