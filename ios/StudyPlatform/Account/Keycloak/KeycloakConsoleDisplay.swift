//
// This source file is part of the StudyPlatform-iOS open source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import SpeziAccount
import SwiftUI


/// `DataDisplayView` that surfaces a link to the Keycloak self-service account console.
public struct KeycloakConsoleDisplay: DataDisplayView {
    public typealias Value = String

    @Environment(KeycloakAccountService.self) private var service
    @Environment(\.openURL) private var openURL

    public init(_ value: String) {}

    public var body: some View {
        Button {
            openURL(service.keycloakConfiguration.issuer.appendingPathComponent("account"))
        } label: {
            HStack {
                Label("Manage Sign-In & Security", systemImage: "person.badge.shield.checkmark")
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
