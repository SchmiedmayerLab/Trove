//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPITypes


/// The performance window of one occurrence: from its opening, inclusive, to its cutoff, exclusive.
///
/// An occurrence without a cutoff has no deadline. Every instant from its opening on lies within the window, and it
/// is never missed.
struct TaskWindow: Equatable, Sendable {
    let opensAt: Date
    let cutoffAt: Date?

    init(opensAt: Date, cutoffAt: Date?) {
        self.opensAt = opensAt
        self.cutoffAt = cutoffAt
    }

    init(_ occurrence: Components.Schemas.ParticipantTaskOccurrence) {
        self.init(opensAt: occurrence.opensAt, cutoffAt: occurrence.cutoffAt)
    }

    /// Whether the participant may perform the occurrence at `instant`.
    func admits(_ instant: Date) -> Bool {
        instant >= opensAt && (cutoffAt.map { instant < $0 } ?? true)
    }

    /// Whether the window closed before `instant`, so the occurrence counts as missed unless it was completed.
    func hasEnded(at instant: Date) -> Bool {
        cutoffAt.map { instant >= $0 } ?? false
    }
}
