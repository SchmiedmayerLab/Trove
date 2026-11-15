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


#else
import Glibc


#endif


/// Reads only a bounded regular deployment file; endpoint/identity settings never come from a participant request.
enum ProviderConfigurationFile {
    static func read(path: String) throws -> Data {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw ProviderFailure.invalidConfiguration }
        let descriptor = path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK) }
        guard descriptor >= 0 else { throw ProviderFailure.invalidConfiguration }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == 0 || info.st_uid == geteuid(), info.st_mode & 0o022 == 0,
              (1...262_144).contains(info.st_size) else { throw ProviderFailure.invalidConfiguration }
        do {
            guard let bytes = try file.read(upToCount: 262_145), (1...262_144).contains(bytes.count) else {
                throw ProviderFailure.invalidConfiguration
            }
            return bytes
        } catch { throw ProviderFailure.invalidConfiguration }
    }
}
