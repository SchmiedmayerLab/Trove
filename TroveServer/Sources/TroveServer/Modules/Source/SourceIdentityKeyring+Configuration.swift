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


#else
import Glibc


#endif


private struct KeyringConfiguration: Codable {
    struct Entry: Codable {
        let id: String
        let keyBase64: String
    }

    let version: Int
    let currentKeyID: String
    let keys: [Entry]
}


extension SourceIdentityKeyring {
    init(configuration bytes: Data) throws {
        guard (1...16_384).contains(bytes.count) else { throw Failure.invalidConfiguration }
        do {
            let configuration = try JSONDecoder().decode(KeyringConfiguration.self, from: bytes)
            guard configuration.version == 1, (1...8).contains(configuration.keys.count) else { throw Failure.invalidConfiguration }
            var keys: [String: SymmetricKey] = [:]
            for entry in configuration.keys {
                guard keys[entry.id] == nil, let key = Data(base64Encoded: entry.keyBase64), key.count == 32,
                      key.base64EncodedString() == entry.keyBase64 else { throw Failure.invalidConfiguration }
                keys[entry.id] = SymmetricKey(data: key)
            }
            try self.init(currentKeyID: configuration.currentKeyID, keys: keys)
        } catch {
            throw Failure.invalidConfiguration
        }
    }

    /// Load once from an operator-mounted secret, independently of the database and participant API.
    /// Follow mounted-secret symlinks, but validate the opened file rather than a race-prone path preflight.
    static func load(file path: String) throws -> Self {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw Failure.invalidConfiguration }
        let descriptor = path.withCString { name in
            #if canImport(Darwin)
            Darwin.open(name, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
            #else
            Glibc.open(name, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
            #endif
        }
        guard descriptor >= 0 else { throw Failure.invalidConfiguration }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == 0 || info.st_uid == geteuid(), info.st_mode & 0o027 == 0,
              (1...16_384).contains(info.st_size) else { throw Failure.invalidConfiguration }
        do {
            let bytes = try file.read(upToCount: 16_385) ?? Data()
            return try Self(configuration: bytes)
        } catch {
            // Do not expose secret contents, decoder diagnostics or secret-file paths.
            throw Failure.invalidConfiguration
        }
    }
}


extension SourceIdentityKeyring {
    /// Explicit operator initialization only. Never reuse this as a recovery or startup fallback.
    /// Exclusive creation also refuses existing empty files and symbolic links.
    static func create(file path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw Failure.creationRefused }
        let descriptor = path.withCString { name in
            #if canImport(Darwin)
            Darwin.open(name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            #else
            Glibc.open(name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            #endif
        }
        guard descriptor >= 0 else { throw Failure.creationRefused }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        do {
            // Apply the intended owner-only mode even when the invoking process has a restrictive umask.
            guard fchmod(descriptor, 0o600) == 0 else { throw Failure.creationRefused }
            let keyID = UUID().uuidString.lowercased()
            let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
            let configuration = KeyringConfiguration(version: 1, currentKeyID: keyID, keys: [.init(id: keyID, keyBase64: key)])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try file.write(contentsOf: encoder.encode(configuration))
            try file.synchronize()
        } catch {
            // Retain an incomplete file on failure. A later invocation must not silently replace it.
            // Decoder, filesystem and crypto diagnostics must not disclose secret bytes or paths.
            throw Failure.creationRefused
        }
    }
}
