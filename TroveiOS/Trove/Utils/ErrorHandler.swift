//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import OSLog
import SwiftUI


@Observable
final class ErrorHandler {
    static let shared = ErrorHandler()

    private let logger = Logger(subsystem: "org.troveplatform.app", category: "ErrorHandler")
    var currentError: (any Error)?

    func handle(_ error: any Error) {
        logger.error("Unhandled error: \(error.localizedDescription, privacy: .public)")
        currentError = error
    }
}

@discardableResult
func catchingTask(
    name: String? = nil,
    priority: TaskPriority? = nil,
    operation: sending @escaping @isolated(any) () async throws -> Void
) -> Task<Void, Never> {
    Task(name: name, priority: priority) {
        do { try await operation() } catch { ErrorHandler.shared.handle(error) }
    }
}

extension View {
    func handlesErrors() -> some View {
        alert(
            "Error",
            isPresented: Binding(
                get: { ErrorHandler.shared.currentError != nil },
                set: { _ in ErrorHandler.shared.currentError = nil }
            ),
            presenting: ErrorHandler.shared.currentError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.localizedDescription)
        }
    }
}
