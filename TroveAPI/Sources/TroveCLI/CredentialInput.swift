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


enum CredentialInput {
    static func read(file: String?, standardInput: Bool) throws -> String {
        guard (file != nil) != standardInput else {
            throw CLIError.invalidCredential
        }
        do {
            if let file {
                return try readFile(file)
            }
            guard isatty(STDIN_FILENO) == 0 else {
                throw CLIError.invalidCredential
            }
            return try token(from: CLIInput.read(FileHandle.standardInput, limit: 16_384))
        } catch {
            throw CLIError.invalidCredential
        }
    }

    private static func readFile(_ path: String) throws -> String {
        // O_NONBLOCK avoids blocking on a FIFO before fstat can reject it.
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw CLIError.invalidCredential
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0,
              metadata.st_size <= 16_384 else {
            throw CLIError.invalidCredential
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return try token(from: CLIInput.read(handle, limit: 16_384))
    }

    static func token(from data: Data) throws -> String {
        guard data.count <= 16_384, let text = String(data: data, encoding: .utf8) else {
            throw CLIError.invalidCredential
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~+/=".utf8)
        guard !value.isEmpty, value.utf8.allSatisfy(allowed.contains) else {
            throw CLIError.invalidCredential
        }
        return value
    }
}
