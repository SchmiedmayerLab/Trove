//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


enum ProviderFailure: Error, Equatable {
    case invalidConfiguration
    case invalidLink
    case unavailable
    case scopeLost
    case ambiguousAccount
    case reauthorizationRequired
    case fenced
    case capacityExceeded
    case invalidPayload
}
