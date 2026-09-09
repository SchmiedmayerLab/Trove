//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import TroveAPIServer


typealias ClinicalEventTarget = EventTargetIntent.Target


/// Maps shared commitment validation failures to sanitized HTTP errors.
struct ClinicalEventIntent: Sendable {
    static let maximumBytes = EventTargetIntent.maximumBytes
    private let value: EventTargetIntent

    var targets: [ClinicalEventTarget] { value.targets }
    var serialized: String { value.serialized }
    var sha256: String { value.sha256 }

    init(targets: [ClinicalEventTarget]) throws {
        do {
            value = try EventTargetIntent(targets: targets)
        } catch EventTargetIntent.ValidationError.oversizedIntent {
            throw ServerError.badRequest("Study target intent exceeds the supported size")
        } catch {
            throw ServerError.badRequest("Provide distinct consent targets and bounded, explicit output addresses")
        }
    }
}
