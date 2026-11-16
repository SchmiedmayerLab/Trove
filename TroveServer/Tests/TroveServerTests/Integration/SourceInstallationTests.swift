//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import SQLKit
import Testing
@testable import TroveServer
import Vapor


struct SourceInstallationTests {
    @Test
    func differentInstallationsRecoverOneLogicalIdentityAndSeparateRepositoriesRemainDistinct() async throws {
        try await Self.withOwner { app, service in
            let firstID = UUID(), secondID = UUID()
            let firstProof = try Self.credential(), secondProof = try Self.credential()
            let first = try await service.register(registrationID: firstID, repositoryKind: .healthKit, credential: firstProof)
            let second = try await service.register(registrationID: secondID, repositoryKind: .healthKit, credential: secondProof)
            #expect(first.source == second.source)
            #expect(first.installation.registrationID != second.installation.registrationID)
            #expect(first.installation.credentialVerifier != second.installation.credentialVerifier)
            #expect(first.source.keyID != firstID && first.source.keyID != secondID)
            let left = try await service.recover(registrationID: firstID, credential: firstProof)
            let right = try await service.recover(registrationID: secondID, credential: secondProof)
            #expect(left.identity.key == right.identity.key)
            #expect(left.identity.context.keyID == right.identity.context.keyID)
            #expect(left.identity.context.repository == right.identity.context.repository)
            let sensorID = UUID()
            let sensor = try await service.register(registrationID: sensorID, repositoryKind: .sensorKit, credential: firstProof)
            #expect(sensor.source.id != first.source.id)
            #expect(sensor.source.keyID != first.source.keyID)
            let sensorScope = try sensor.source.repositoryScope
            let healthScope = try first.source.repositoryScope
            #expect(sensorScope != healthScope)
            let sql = try #require(app.db as? any SQLDatabase)
            let rows = try await sql.raw("SELECT COUNT(*) AS count FROM audit_events WHERE action = 'source.identity.disclosure'").all()
            let audit = try #require(rows.first)
            #expect(try audit.decode(column: "count", as: Int.self) == 2)
        }
    }

    @Test
    func installationRevocationDoesNotRevokeOtherInstallationsOrMintReplacementIdentity() async throws {
        try await Self.withOwner { app, service in
            let firstID = UUID(), secondID = UUID()
            let proof = try Self.credential()
            let first = try await service.register(registrationID: firstID, repositoryKind: .healthKit, credential: proof)
            let second = try await service.register(registrationID: secondID, repositoryKind: .healthKit, credential: proof)
            let revoked = try await service.revoke(registrationID: firstID)
            #expect(revoked.source.revokedAt == nil)
            #expect(revoked.installation.revokedAt != nil)
            #expect(try await service.revoke(registrationID: firstID) == revoked)
            #expect(try await service.register(registrationID: firstID, repositoryKind: .healthKit, credential: proof) == revoked)
            await #expect { try await service.recover(registrationID: firstID, credential: proof) } throws: {
                ($0 as? ServerError)?.status.code == 409
            }
            #expect(try await service.recover(registrationID: secondID, credential: proof).registration == second)
            _ = try await SourceBindingService(database: app.db).revoke(id: first.source.id)
            await #expect { try await service.recover(registrationID: secondID, credential: proof) } throws: {
                ($0 as? ServerError)?.status.code == 409
            }
            await #expect { try await service.register(registrationID: UUID(), repositoryKind: .healthKit, credential: proof) } throws: {
                ($0 as? ServerError)?.status.code == 409
            }
        }
    }

    @Test
    func credentialAndRepositoryMismatchCannotChangeRegistrationOrDiscloseKeys() async throws {
        try await Self.withOwner { _, service in
            let id = UUID()
            let proof = try Self.credential(), wrong = try Self.credential()
            let registered = try await service.register(registrationID: id, repositoryKind: .healthKit, credential: proof)
            await #expect { try await service.register(registrationID: id, repositoryKind: .healthKit, credential: wrong) } throws: {
                ($0 as? ServerError)?.status.code == 403
            }
            await #expect { try await service.recover(registrationID: id, credential: wrong) } throws: {
                ($0 as? ServerError)?.status.code == 403
            }
            await #expect { try await service.register(registrationID: id, repositoryKind: .sensorKit, credential: proof) } throws: {
                ($0 as? ServerError)?.status.code == 409
            }
            #expect(try await service.find(registrationID: id) == registered)
            await AuthContext.$current.withValue(ClinicalEventStoreTests.researcher) {
                await #expect { try await service.recover(registrationID: id, credential: proof) } throws: {
                    ($0 as? ServerError)?.status.code == 403
                }
            }
        }
    }

    @Test
    func unavailableDecryptionNeverRegistersAnotherInstallationOrReplacesTheKey() async throws {
        try await Self.withOwner { app, service in
            let id = UUID(), secondID = UUID()
            let proof = try Self.credential()
            let registered = try await service.register(registrationID: id, repositoryKind: .healthKit, credential: proof)
            let unavailable = SourceInstallationService(
                database: app.db, keyring: try .init(currentKeyID: "unrelated", keys: ["unrelated": SymmetricKey(size: .bits256)])
            )
            await #expect { try await unavailable.recover(registrationID: id, credential: proof) } throws: {
                ($0 as? ServerError)?.status.code == 503
            }
            await #expect { try await unavailable.register(registrationID: secondID, repositoryKind: .healthKit, credential: proof) } throws: {
                ($0 as? ServerError)?.status.code == 503
            }
            await #expect { try await service.find(registrationID: secondID) } throws: { ($0 as? ServerError)?.status.code == 404 }
            #expect(try await service.recover(registrationID: id, credential: proof).registration == registered)
        }
    }

    @Test
    func failedDisclosureAuditReleasesNoKeyAndHistoryCannotBeDropped() async throws {
        try await Self.withOwner { app, service in
            let id = UUID()
            let proof = try Self.credential()
            let registered = try await service.register(registrationID: id, repositoryKind: .healthKit, credential: proof)
            await #expect(throws: CreateSourceInstallations.RollbackError.self) { try await CreateSourceInstallations().revert(on: app.db) }
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("DROP TABLE audit_events").run()
            await #expect(throws: (any Error).self) { try await service.recover(registrationID: id, credential: proof) }
            #expect(try await service.find(registrationID: id) == registered)
        }
    }
}


extension SourceInstallationTests {
    private static func credential() throws -> SourceInstallationCredential {
        try .init(base64: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() })
    }

    private static func withOwner(_ test: @escaping @Sendable (Application, SourceInstallationService) async throws -> Void) async throws {
        try await TestApp.withApp { app, _ in
            try await ParticipantFixtures.createParticipant(on: app.db)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await test(app, app.grove[SourceInstallationService.self])
            }
        }
    }
}
