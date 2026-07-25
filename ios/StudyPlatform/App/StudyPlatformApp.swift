//
// This source file is part of the StudyPlatform-iOS open source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Spezi
import SwiftUI

@main
struct StudyPlatformApp: App {
    @UIApplicationDelegateAdaptor(StudyPlatformAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .spezi(appDelegate)
        }
    }
}
