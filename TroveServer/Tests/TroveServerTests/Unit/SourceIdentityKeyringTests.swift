//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import GroveFHIRContract
import Testing
@testable import TroveServer


struct SourceIdentityKeyringTests {
    @Test
    func encryptionRotationPreservesTheParticipantKeyAndGroveIdentifiers() throws {
        let identity = SymmetricKey(size: .bits256)
        let oldEncryption = SymmetricKey(size: .bits256)
        let newEncryption = SymmetricKey(size: .bits256)
        let original = try SourceIdentityKeyring(currentKeyID: "old", keys: ["old": oldEncryption])
        let rotating = try SourceIdentityKeyring(currentKeyID: "new", keys: ["old": oldEncryption, "new": newEncryption])
        let retired = try SourceIdentityKeyring(currentKeyID: "new", keys: ["new": newEncryption])
        let context = try Self.context()
        let envelope = try original.seal(identity, context: context)
        let rewrapped = try rotating.rewrap(envelope, context: context)
        #expect(rewrapped.encryptionKeyID == "new")
        #expect(rewrapped.sealedKey != envelope.sealedKey)
        let recovered = try retired.open(rewrapped, context: context)
        #expect(recovered == identity)
        #expect(try Self.recordIdentifier(key: recovered, context: context) == Self.recordIdentifier(key: identity, context: context))
        #expect(try retired.rewrap(rewrapped, context: context) == rewrapped)
        #expect(throws: SourceIdentityKeyring.Failure.recoveryUnavailable) { try retired.open(envelope, context: context) }
        #expect(try original.open(envelope, context: context) == identity)
    }

    @Test
    func encryptionUsesFreshNoncesAndStoresOnlyCiphertext() throws {
        let ring = try SourceIdentityKeyring(currentKeyID: "current", keys: ["current": SymmetricKey(size: .bits256)])
        let key = SymmetricKey(size: .bits256)
        let context = try Self.context()
        let first = try ring.seal(key, context: context)
        let second = try ring.seal(key, context: context)
        #expect(first.sealedKey.count == 60)
        #expect(first.sealedKey.prefix(12) != second.sealedKey.prefix(12))
        #expect(try ring.open(first, context: context) == key)
        #expect(try ring.open(second, context: context) == key)
        #expect(!first.sealedKey.contains(key.withUnsafeBytes { Data($0) }))
        #expect(String(describing: ring) == "SourceIdentityKeyring(redacted)")
        #expect(String(reflecting: ring) == "SourceIdentityKeyring(redacted)")
        #expect(Mirror(reflecting: ring).children.isEmpty)
    }

    @Test(arguments: [0, 12, 44, 59])
    func nonceCiphertextAndAuthenticationTagTamperingCannotRecoverOrRewrap(offset: Int) throws {
        let ring = try SourceIdentityKeyring(currentKeyID: "current", keys: ["current": SymmetricKey(size: .bits256)])
        let context = try Self.context()
        let envelope = try ring.seal(SymmetricKey(size: .bits256), context: context)
        var bytes = envelope.sealedKey
        bytes[offset] ^= 1
        let tampered = SourceIdentityKeyring.Envelope(version: 1, encryptionKeyID: "current", sealedKey: bytes)
        #expect(throws: SourceIdentityKeyring.Failure.recoveryUnavailable) { try ring.open(tampered, context: context) }
        #expect(throws: SourceIdentityKeyring.Failure.recoveryUnavailable) { try ring.rewrap(tampered, context: context) }
    }

    @Test(arguments: ["participant", "source", "key", "epoch", "root", "repository-system", "repository-value"])
    func swappingAnyIdentityOrAuthorityFieldRejectsRecovery(field: String) throws {
        let ring = try SourceIdentityKeyring(currentKeyID: "current", keys: ["current": SymmetricKey(size: .bits256)])
        let context = try Self.context()
        let envelope = try ring.seal(SymmetricKey(size: .bits256), context: context)
        let changed = try SourceIdentityKeyContext(
            owner: (field == "participant" ? UUID() : context.participantID, field == "source" ? UUID() : context.sourceID),
            keyID: field == "key" ? UUID() : context.keyID,
            epoch: field == "epoch" ? KeyEpoch(2) : context.epoch,
            identifierRoot: field == "root" ? context.identifierRoot + "-other" : context.identifierRoot,
            repository: BusinessIdentifier(
                system: IdentifierSystem(field == "repository-system" ? "https://other.test/repository" : context.repository.system.rawValue),
                value: field == "repository-value" ? "another-repository" : context.repository.value
            )
        )
        #expect(throws: SourceIdentityKeyring.Failure.recoveryUnavailable) { try ring.open(envelope, context: changed) }
        #expect(throws: SourceIdentityKeyring.Failure.recoveryUnavailable) { try ring.rewrap(envelope, context: changed) }
    }

    @Test
    func envelopeHeaderAndUnavailableOrWrongEncryptionKeysFailClosed() throws {
        let encryption = SymmetricKey(size: .bits256)
        let ring = try SourceIdentityKeyring(currentKeyID: "current", keys: ["current": encryption, "alias": encryption])
        let context = try Self.context()
        let envelope = try ring.seal(SymmetricKey(size: .bits256), context: context)
        let wrong = try SourceIdentityKeyring(currentKeyID: "current", keys: ["current": SymmetricKey(size: .bits256)])
        #expect(throws: SourceIdentityKeyring.Failure.recoveryUnavailable) { try wrong.open(envelope, context: context) }
        let malformed: [SourceIdentityKeyring.Envelope] = [
            .init(version: 2, encryptionKeyID: "current", sealedKey: envelope.sealedKey),
            .init(version: 1, encryptionKeyID: "missing", sealedKey: envelope.sealedKey),
            .init(version: 1, encryptionKeyID: "alias", sealedKey: envelope.sealedKey),
            .init(version: 1, encryptionKeyID: "current", sealedKey: envelope.sealedKey.dropLast()),
            .init(version: 1, encryptionKeyID: "current", sealedKey: envelope.sealedKey + Data([0]))
        ]
        for value in malformed {
            #expect(throws: SourceIdentityKeyring.Failure.recoveryUnavailable) { try ring.open(value, context: context) }
        }
    }

    @Test
    func invalidKeySizesAndOversizedContextCannotBePersisted() throws {
        #expect(throws: SourceIdentityKeyring.Failure.invalidConfiguration) {
            try SourceIdentityKeyring(currentKeyID: "short", keys: ["short": SymmetricKey(size: .bits128)])
        }
        let ring = try SourceIdentityKeyring(currentKeyID: "current", keys: ["current": SymmetricKey(size: .bits256)])
        let context = try Self.context()
        #expect(throws: SourceIdentityKeyring.Failure.invalidIdentityKey) {
            try ring.seal(SymmetricKey(size: .bits128), context: context)
        }
        #expect(throws: SourceIdentityKeyring.Failure.invalidContext) {
            try SourceIdentityKeyContext(
                owner: (context.participantID, context.sourceID),
                keyID: context.keyID,
                epoch: context.epoch,
                identifierRoot: context.identifierRoot,
                repository: BusinessIdentifier(system: context.repository.system, value: String(repeating: "x", count: 257))
            )
        }
    }
}


extension SourceIdentityKeyringTests {
    private static func context() throws -> SourceIdentityKeyContext {
        try SourceIdentityKeyContext(
            owner: (UUID(), UUID()),
            keyID: UUID(),
            epoch: KeyEpoch(1),
            identifierRoot: "https://trove.test/sources/logical-source",
            repository: BusinessIdentifier(system: IdentifierSystem("https://trove.test/repository"), value: "healthkit")
        )
    }

    private static func recordIdentifier(key: SymmetricKey, context: SourceIdentityKeyContext) throws -> RoledIdentifier {
        let scope = try OpaqueIdentityScope(
            root: IdentifierSystem(context.identifierRoot), keyID: context.keyID.uuidString.lowercased(), epoch: context.epoch, key: key
        )
        return try scope.sourceRecord(
            adapterID: "healthkit",
            sourceType: "HKQuantityTypeIdentifierHeartRate",
            repositoryScope: context.repository,
            nativeRecordID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        ).identifier
    }
}
