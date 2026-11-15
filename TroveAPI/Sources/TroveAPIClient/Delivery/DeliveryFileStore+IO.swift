//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


#if canImport(Darwin)
import Darwin


#elseif canImport(Glibc)
import Glibc


#endif


extension DeliveryFileStore {
    static func attributes(_ file: Int32) throws -> stat {
        var attributes = stat()
        guard fstat(file, &attributes) == 0,
              attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              attributes.st_mode & 0o777 == 0o600, attributes.st_uid == geteuid(), attributes.st_nlink == 1 else {
            throw Failure.unsafeFile
        }
        return attributes
    }

    static func verify(_ reservation: Reservation, file: Int32) throws {
        let attributes = try attributes(file)
        guard String(attributes.st_dev) == reservation.device, String(attributes.st_ino) == reservation.inode else {
            throw Failure.changedFile
        }
    }

    static func writeChunk(_ bytes: Data, to file: Int32) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                #if canImport(Darwin)
                let count = Darwin.write(file, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                #else
                let count = Glibc.write(file, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                #endif
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.writeFailed }
                offset += count
            }
        }
    }

    static func synchronize(_ file: Int32, regularFile: Bool) throws {
        while fsync(file) != 0 {
            guard errno == EINTR else { throw Failure.durabilityFailed }
        }
        #if canImport(Darwin)
        if regularFile {
            while fcntl(file, F_FULLFSYNC) != 0 {
                guard errno == EINTR else { throw Failure.durabilityFailed }
            }
        }
        #endif
    }
}
