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
                healthKitSection
                ProviderConnectionsSection()
                SavedCollectionSection()
                HealthDataExplanationView()
            }
            .disabled(model.status == .signedOut || scenePhase != .active)
            .navigationTitle("Health Data")
            .refreshable {
                await model.run(.refresh)
                await model.refreshCollectionSettings()
            }
            .task(id: model.sessionSnapshot) {
                await model.run(.refresh)
                await model.refreshCollectionSettings()
            }
            .task(id: scenePhase == .active ? action : nil) {
                guard scenePhase == .active, let action else {
                    return
                }
                await model.run(action)
                await model.refreshCollectionSettings()
                self.action = nil
            }
        }
    }

    private var healthKitSection: some View {
        Section("HealthKit Data") {
            Text(model.status.message)
            if model.isReviewingDocuments {
                ProgressView("Reviewing Health Documents…")
                Button("Cancel Document Review", role: .cancel) { model.cancelDocumentReview() }
            } else if model.isBusy {
                ProgressView("Working…")
            }
            Button("Set Up This Device") { action = .setUp }
                .disabled(model.isBusy || model.status != .notSetUp)
            Button("Review Health Access") { action = .requestAccess }
                .disabled(model.isBusy || model.status == .notSetUp || model.status == .revoked)
            Button("Review Health Documents") { action = .reviewDocuments }
                .disabled(model.isBusy || model.status == .notSetUp || model.status == .revoked)
            Text("Health may ask you to approve individual documents requested by your studies.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Sync Available Data") { action = .sync }
                .disabled(model.isBusy || model.status == .notSetUp)
        }
    }
}
