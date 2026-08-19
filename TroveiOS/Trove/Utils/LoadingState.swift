//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Generic loading state used by feature-level Modules that fetch a value over the network.
///
/// Refreshes preserve the last resolved value so views can distinguish an unavailable value from a
/// loaded empty value. Callers should only enable domain actions while ``isLoaded`` is `true`.
enum LoadingState<Value: Sendable>: Sendable {
    case idle
    case loading(previous: Value?)
    case loaded(Value)
    case failed(error: any Error, previous: Value?)

    var value: Value? {
        switch self {
        case .loaded(let value):
            return value
        case .loading(let previous), .failed(_, let previous):
            return previous
        case .idle:
            return nil
        }
    }

    var isLoading: Bool {
        if case .loading = self {
            return true
        }
        return false
    }

    var isLoaded: Bool {
        if case .loaded = self {
            return true
        }
        return false
    }

    var error: (any Error)? {
        if case .failed(let error, _) = self {
            return error
        }
        return nil
    }

    mutating func beginLoading(preservingValue: Bool = true) {
        self = .loading(previous: preservingValue ? value : nil)
    }

    mutating func resolve(with value: Value) {
        self = .loaded(value)
    }

    mutating func reject(with error: any Error) {
        self = .failed(error: error, previous: value)
    }

    mutating func cancelLoading() {
        self = value.map(Self.loaded) ?? .idle
    }
}
