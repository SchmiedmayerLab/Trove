//
// This source file is part of the StudyPlatform-iOS open source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation

/// Generic loading state used by feature-level Modules that fetch a value over the network.
///
/// A simple state machine; modules go `idle → loading → loaded(_)` on success or `… → failed(_)`
/// on error. Modules should preserve the previous `.loaded(_)` payload across re-fetches by only
/// transitioning to `.loading` from `.idle` so views can keep rendering data while a refresh runs.
enum LoadingState<Value: Sendable>: Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(any Error)

    var value: Value? {
        if case .loaded(let value) = self {
            return value
        }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self {
            return true
        }
        return false
    }
}
