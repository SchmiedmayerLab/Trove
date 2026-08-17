//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Grove
import SwiftUI


@main
struct TroveApp: App {
    @UIApplicationDelegateAdaptor(TroveAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .grove(appDelegate)
        }
    }
}
