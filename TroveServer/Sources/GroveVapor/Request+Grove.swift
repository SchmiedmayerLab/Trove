//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if canImport(Vapor)
import Vapor


@available(macOS 26, iOS 26, watchOS 26, tvOS 26, visionOS 26, *)
extension Request {
    /// Access Grove modules in route handlers.
    public var grove: GroveVapor {
        GroveVapor(request: self)
    }
}
#endif
