//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing


@testable import TroveServer


/// An occurrence may have no deadline: its window has no end, it is never missed, and it admits every later instant.
struct TaskWindowBoundsTests {
    @Test
    func aWindowWithoutAnEndAdmitsEveryLaterInstantAndNeverEnds() {
        let opens = Date(timeIntervalSince1970: 1_800_000_000)
        let open = TaskWindow(opensAt: opens, cutoffAt: nil)
        for offset: TimeInterval in [0, 1, 86_400, 3_650 * 86_400] {
            #expect(open.admits(opens.addingTimeInterval(offset)))
            #expect(!open.hasEnded(at: opens.addingTimeInterval(offset)))
        }
        #expect(!open.admits(opens.addingTimeInterval(-1)))
        let bounded = TaskWindow(opensAt: opens, cutoffAt: opens.addingTimeInterval(60))
        #expect(bounded.admits(opens.addingTimeInterval(59)))
        #expect(!bounded.admits(opens.addingTimeInterval(60)) && bounded.hasEnded(at: opens.addingTimeInterval(60)))
        #expect(!bounded.hasEnded(at: opens.addingTimeInterval(59)))
    }
}
