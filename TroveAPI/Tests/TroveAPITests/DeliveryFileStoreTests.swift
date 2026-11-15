//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import Testing
@testable import TroveAPIClient


struct DeliveryFileStoreTests {
    private enum InputFailure: Error { case interrupted }

    @Test
    func largeFileSurvivesReopeningWithExactBytesAndDurableIdentity() async throws {
        try await DeliveryFixture.withJournal { _, database in
            let directory = database.deletingLastPathComponent().appendingPathComponent("files", isDirectory: true)
            let store = try DeliveryFileStore(directory: directory, create: true)
            let reservation = try store.reserve()
            let count = 64 * 1024 * 1024 + 17
            let chunk = Data(repeating: 0xA5, count: DeliveryFileStore.chunkBytes)
            let digest = try store.write(reservation, byteCount: count) { consume in
                for _ in 0..<1024 { try consume(chunk) }
                try consume(chunk.prefix(17))
            }
            let retained = try JSONDecoder().decode(DeliveryFileStore.Reservation.self, from: JSONEncoder().encode(reservation))
            let reopened = try DeliveryFileStore(directory: directory, create: false)
            let url = try reopened.verifiedURL(retained, byteCount: count)
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hash = SHA256(), read = 0
            while let bytes = try file.read(upToCount: DeliveryFileStore.chunkBytes), !bytes.isEmpty {
                hash.update(data: bytes)
                read += bytes.count
            }
            #expect(read == count)
            #expect(digest == hash.finalize().map { String(format: "%02x", $0) }.joined())
            #expect(throws: DeliveryFileStore.Failure.changedFile) {
                try reopened.write(retained, byteCount: 1) { try $0(Data([1])) }
            }
            try reopened.remove(retained)
            try reopened.remove(retained)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test(arguments: ["short", "long", "chunk", "interrupted"])
    func failedWritesCannotReturnACommitmentAndRemainRecoverable(reason: String) async throws {
        try await DeliveryFixture.withJournal { _, database in
            let directory = database.deletingLastPathComponent().appendingPathComponent("files", isDirectory: true)
            let store = try DeliveryFileStore(directory: directory, create: true)
            let reservation = try store.reserve()
            #expect(throws: (any Error).self) {
                try store.write(reservation, byteCount: 3) { consume in
                    try consume(Data([1]))
                    switch reason {
                    case "long": try consume(Data([2, 3, 4]))
                    case "chunk": try consume(Data(repeating: 0, count: DeliveryFileStore.chunkBytes + 1))
                    case "interrupted": throw InputFailure.interrupted
                    default: break
                    }
                }
            }
            let reopened = try DeliveryFileStore(directory: directory, create: false)
            try reopened.remove(reservation)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    @Test
    func replacementAndUnindexedFilesArePreservedDuringRecovery() async throws {
        try await DeliveryFixture.withJournal { _, database in
            let directory = database.deletingLastPathComponent().appendingPathComponent("files", isDirectory: true)
            let store = try DeliveryFileStore(directory: directory, create: true)
            let reservation = try store.reserve()
            let path = directory.appendingPathComponent(reservation.name)
            let saved = directory.appendingPathComponent("saved")
            try FileManager.default.moveItem(at: path, to: saved)
            let foreign = Data("preserve this file".utf8)
            try foreign.write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            #expect(throws: DeliveryFileStore.Failure.changedFile) { try store.remove(reservation) }
            #expect(try Data(contentsOf: path) == foreign)
            #expect(FileManager.default.fileExists(atPath: saved.path))
            #expect(throws: DeliveryFileStore.Failure.unavailable) { try DeliveryFileStore(directory: directory, create: true) }
            #expect(try Data(contentsOf: path) == foreign)
        }
    }

    @Test(arguments: [false, true])
    func linksCannotBeUsedForWritingOrCleanup(hardLink: Bool) async throws {
        try await DeliveryFixture.withJournal { _, database in
            let directory = database.deletingLastPathComponent().appendingPathComponent("files", isDirectory: true)
            let store = try DeliveryFileStore(directory: directory, create: true)
            let reservation = try store.reserve()
            let path = directory.appendingPathComponent(reservation.name)
            let other = directory.appendingPathComponent("preserved")
            if hardLink {
                try FileManager.default.linkItem(at: path, to: other)
            } else {
                try FileManager.default.moveItem(at: path, to: other)
                try FileManager.default.createSymbolicLink(at: path, withDestinationURL: other)
            }
            #expect(throws: (any Error).self) { try store.write(reservation, byteCount: 1) { try $0(Data([1])) } }
            #expect(throws: (any Error).self) { try store.remove(reservation) }
            #expect(try Data(contentsOf: other).isEmpty)
            #expect(FileManager.default.fileExists(atPath: path.path))
        }
    }
}
