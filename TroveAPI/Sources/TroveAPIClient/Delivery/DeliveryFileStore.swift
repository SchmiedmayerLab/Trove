//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation


#if canImport(Darwin)
import Darwin


#elseif canImport(Glibc)
import Glibc


#endif


/// Private files owned by a journal's durable reservation rows. All operations run under its SQLite writer transaction.
/// A reservation must commit before writing payload bytes; recovery removes only the recorded inode, never unknown files.
final class DeliveryFileStore {
    struct Reservation: Codable, Sendable, Equatable {
        let id: UUID
        let device: String
        let inode: String

        var name: String { id.uuidString.lowercased() + ".recording" }
    }

    enum Failure: Error, Equatable {
        case unavailable
        case unsafeFile
        case changedFile
        case invalidSize
        case writeFailed
        case durabilityFailed
    }

    static let chunkBytes = 64 * 1024
    let directory: URL
    private let descriptor: Int32

    init(directory: URL, create: Bool) throws {
        guard directory.isFileURL, !directory.path.utf8.contains(0) else { throw Failure.unavailable }
        try DeliveryJournalSchema.checkProtection(of: directory.deletingLastPathComponent())
        if create {
            guard mkdir(directory.path, 0o700) == 0 else { throw Failure.unavailable }
            #if os(iOS) || os(watchOS) || os(visionOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path
            )
            var directory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            #endif
        }
        try DeliveryJournalSchema.checkProtection(of: directory)
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unavailable }
        do {
            var attributes = stat()
            guard fstat(descriptor, &attributes) == 0, attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  attributes.st_mode & 0o777 == 0o700, attributes.st_uid == geteuid() else { throw Failure.unsafeFile }
            if create {
                let parent = open(directory.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard parent >= 0 else { throw Failure.unavailable }
                defer { close(parent) }
                try Self.synchronize(parent, regularFile: false)
            }
        } catch {
            close(descriptor)
            throw error
        }
        self.directory = directory
        self.descriptor = descriptor
    }

    /// Creates an empty file. The caller persists this identity before any recording bytes are written.
    func reserve() throws -> Reservation {
        try Task.checkCancellation()
        let id = UUID()
        let name = id.uuidString.lowercased() + ".recording"
        let file = openat(descriptor, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Failure.unavailable }
        defer { close(file) }
        #if os(iOS) || os(watchOS) || os(visionOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.appendingPathComponent(name).path
        )
        #endif
        let attributes = try Self.attributes(file)
        let reservation = Reservation(id: id, device: String(attributes.st_dev), inode: String(attributes.st_ino))
        try Self.synchronize(file, regularFile: true)
        try Self.synchronize(descriptor, regularFile: false)
        return reservation
    }

    /// Writes only an empty reservation, hashing exact bounded chunks. An interrupted write is never resumed or truncated.
    /// Its durable reservation permits later cleanup; retry creates a fresh file.
    func write(
        _ reservation: Reservation, byteCount: Int, read: (_ consume: (Data) throws -> Void) throws -> Void
    ) throws -> String {
        guard (1...Int(Int32.max)).contains(byteCount) else { throw Failure.invalidSize }
        let file = try openReservation(reservation, flags: O_WRONLY)
        defer { close(file) }
        guard try Self.attributes(file).st_size == 0 else { throw Failure.changedFile }
        var written = 0
        var hasher = SHA256()
        try read { bytes in
            try Task.checkCancellation()
            guard bytes.count <= Self.chunkBytes, bytes.count <= byteCount - written else { throw Failure.invalidSize }
            try Self.writeChunk(bytes, to: file)
            hasher.update(data: bytes)
            written += bytes.count
        }
        try Task.checkCancellation()
        guard written == byteCount else { throw Failure.invalidSize }
        try Self.synchronize(file, regularFile: true)
        try Self.synchronize(descriptor, regularFile: false)
        _ = try verifiedURL(reservation, byteCount: byteCount)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Locate an exact owned file for an immutable Grove snapshot. The caller also verifies its retained digest.
    func verifiedURL(_ reservation: Reservation, byteCount: Int) throws -> URL {
        guard (1...Int(Int32.max)).contains(byteCount) else { throw Failure.invalidSize }
        let file = try openReservation(reservation, flags: O_RDONLY)
        defer { close(file) }
        guard try Self.attributes(file).st_size == byteCount else { throw Failure.changedFile }
        return directory.appendingPathComponent(reservation.name)
    }

    /// Idempotent recovery. A different inode, symlink or hard link is preserved and reported, never removed.
    func remove(_ reservation: Reservation) throws {
        let file = openat(descriptor, reservation.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0, errno == ENOENT {
            try Self.synchronize(descriptor, regularFile: false)
            return
        }
        guard file >= 0 else { throw Failure.unavailable }
        defer { close(file) }
        try Self.verify(reservation, file: file)
        guard unlinkat(descriptor, reservation.name, 0) == 0 else { throw Failure.unavailable }
        try Self.synchronize(descriptor, regularFile: false)
    }

    private func openReservation(_ reservation: Reservation, flags: Int32) throws -> Int32 {
        try Task.checkCancellation()
        try DeliveryJournalSchema.checkProtection(of: directory.appendingPathComponent(reservation.name))
        let file = openat(descriptor, reservation.name, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw Failure.unavailable }
        do {
            try Self.verify(reservation, file: file)
            return file
        } catch {
            close(file)
            throw error
        }
    }

    deinit { close(descriptor) }
}
