//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

extension HealthDataStatus {
    /// One queue status after both adapters have had a collection opportunity.
    static func combining(_ adapters: [Self], pending: Bool, synchronized: Bool) -> Self {
        let actionable: [Self] = [
            .blocked, .historyUnavailable, .storageFull, .refreshNeeded, .sensorConfigurationRequired,
            .permissionNeeded, .catchUpPending, .revoked, .notSetUp
        ]
        if let status = actionable.first(where: adapters.contains) {
            return status
        }
        if pending {
            return .waiting
        }
        if adapters.contains(.unavailable) {
            return .unavailable
        }
        if adapters.contains(.permissionRequested) {
            return .permissionRequested
        }
        if adapters.contains(where: { [.ready, .waiting, .syncFinished].contains($0) }) {
            return synchronized ? .syncFinished : .ready
        }
        return .notAuthorized
    }
}
