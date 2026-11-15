//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Samples the process's resident memory for large-transfer tests on Linux.
enum ResidentMemory {
    /// The process's current resident memory, or `nil` where `/proc` does not report it.
    ///
    /// Unlike the peak resident memory (`VmHWM`), the current value does not carry the high-water mark that earlier tests
    /// in the same process left behind.
    static func currentBytes() -> Int? {
        #if os(Linux)
        guard let statm = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) else {
            return nil
        }
        let fields = statm.split(separator: " ")
        guard fields.count > 1, let pages = Int(fields[1]) else {
            return nil
        }
        return pages * Int(getpagesize())
        #else
        return nil
        #endif
    }

    /// Runs `operation` while sampling the resident memory, and returns its result with how far the highest sample rose
    /// above the resident memory before it started, or `nil` where `/proc` does not report it.
    static func growth<Result: Sendable>(
        during operation: () async throws -> Result
    ) async throws -> (result: Result, growthBytes: Int?) {
        let baseline = currentBytes()
        let sampler = Task.detached { () -> Int? in
            var peak = currentBytes()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2))
                peak = max(peak ?? 0, currentBytes() ?? 0)
            }
            return peak
        }
        defer { sampler.cancel() }
        let result = try await operation()
        sampler.cancel()
        guard let baseline, let peak = await sampler.value else {
            return (result, nil)
        }
        return (result, peak - baseline)
    }
}
