//
// This source file is part of the StudyPlatform-iOS open source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SpeziLocalization

extension LocalizationKey {
    /// The current locale's `LocalizationKey`, falling back to `en-US` when the system locale
    /// has no region (e.g. `Locale(identifier: "fr")`).
    static var currentOrDefault: LocalizationKey {
        LocalizationKey(locale: .current) ?? .enUS
    }
}
