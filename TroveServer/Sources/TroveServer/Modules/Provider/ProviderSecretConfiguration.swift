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


/// An operator-mounted secret. No startup fallback generates replacement decryption keys.
struct ProviderSecretConfiguration: Sendable {
    private struct Document: Decodable {
        struct Key: Decodable {
            let id: String
            let keyBase64: String
        }
        struct Application: Decodable {
            let registrationID: UUID
            let clientSecret: String
        }
        let version: Int
        let currentKeyID: String
        let keys: [Key]
        let applications: [Application]
    }

    let vault: ProviderCredentialVault
    let applications: ProviderApplicationSecrets

    init(bytes: Data) throws {
        guard (1...262_144).contains(bytes.count) else { throw ProviderFailure.invalidConfiguration }
        do {
            let document = try JSONDecoder().decode(Document.self, from: bytes)
            guard document.version == 1, (1...8).contains(document.keys.count), document.applications.count <= 128 else {
                throw ProviderFailure.invalidConfiguration
            }
            var keys: [String: SymmetricKey] = [:]
            for entry in document.keys {
                guard keys[entry.id] == nil, let bytes = Data(base64Encoded: entry.keyBase64), bytes.count == 32,
                      bytes.base64EncodedString() == entry.keyBase64 else { throw ProviderFailure.invalidConfiguration }
                keys[entry.id] = SymmetricKey(data: bytes)
            }
            var applications: [UUID: String] = [:]
            for entry in document.applications {
                guard applications.updateValue(entry.clientSecret, forKey: entry.registrationID) == nil else {
                    throw ProviderFailure.invalidConfiguration
                }
            }
            self.vault = try .init(currentKeyID: document.currentKeyID, keys: keys)
            self.applications = try .init(applications)
        } catch { throw ProviderFailure.invalidConfiguration }
    }

    static func load(file path: String) throws -> Self {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw ProviderFailure.invalidConfiguration }
        let descriptor = path.withCString { name in
            #if canImport(Darwin)
            Darwin.open(name, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
            #else
            Glibc.open(name, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
            #endif
        }
        guard descriptor >= 0 else { throw ProviderFailure.invalidConfiguration }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == 0 || info.st_uid == geteuid(), info.st_mode & 0o027 == 0,
              (1...262_144).contains(info.st_size) else { throw ProviderFailure.invalidConfiguration }
        do {
            return try Self(bytes: file.read(upToCount: 262_145) ?? Data())
        } catch { throw ProviderFailure.invalidConfiguration }
    }
}
