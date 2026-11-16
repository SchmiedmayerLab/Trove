//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveSensorKit
import TroveSensorKit


/// Deployment selection is narrower than the adapter inventory and must match the signed sensor grants.
enum SensorDataConfiguration {
    static var sources: [SensorKitCollectionSource] { sources(in: .main) }

    static func sources(in bundle: Bundle) -> [SensorKitCollectionSource] {
        guard GroveSensorKit.SensorKit.isAvailable else {
            return []
        }
        return selectedSources(
            enabled: bundle.object(forInfoDictionaryKey: "TroveSensorKitEnabled") as? String,
            privacyPolicyURL: bundle.object(forInfoDictionaryKey: "NSSensorKitPrivacyPolicyURL") as? String,
            identifiers: bundle.object(forInfoDictionaryKey: "TroveSensorKitSources") as? [String] ?? []
        ).filter { $0.sensor != nil }
    }

    static func selectedSources(enabled: String?, privacyPolicyURL: String?, identifiers: [String]) -> [SensorKitCollectionSource] {
        guard enabled == "YES", let privacyPolicyURL,
              let url = URL(string: privacyPolicyURL), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, !privacyPolicyURL.contains("$(") else {
            return []
        }
        let sources = identifiers.compactMap(SensorKitCollectionSource.init(rawValue:))
        guard sources.count == identifiers.count, Set(sources).count == sources.count else {
            return []
        }
        return sources
    }

    @MainActor
    static func stopRecording() async throws {
        var failure: (any Error)?
        for source in sources where source.sensor?.authorizationStatus == .authorized {
            do { try await source.sensor?.stopRecording() } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }
}
