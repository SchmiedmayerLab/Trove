//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import SwiftUI


struct HealthDataView: View {
    @Environment(HealthDataModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var action: HealthDataModel.Action?

    var body: some View {
        NavigationStack {
            Form {
                Section("Heart Rate") {
                    Text(model.status.message)
                    if model.isBusy { ProgressView("Working…") }
                    Button("Set Up This Device") { action = .setUp }
                        .disabled(model.isBusy || model.status != .notSetUp)
                    Button("Review Health Access") { action = .requestAccess }
                        .disabled(model.isBusy || model.status == .notSetUp || model.status == .revoked)
                    Button("Sync Available Data") { action = .sync }
                        .disabled(model.isBusy || model.status == .notSetUp)
                }
                HealthDataExplanationView()
            }
            .disabled(model.status == .signedOut || scenePhase != .active)
            .navigationTitle("Health Data")
            .refreshable { await model.run(.refresh) }
            .task { await model.run(.refresh) }
            .task(id: scenePhase == .active ? action : nil) {
                guard scenePhase == .active, let action else {
                    return
                }
                await model.run(action)
                self.action = nil
            }
        }
    }
}
