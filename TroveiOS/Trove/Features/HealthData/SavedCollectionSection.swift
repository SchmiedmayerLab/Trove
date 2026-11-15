//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveLocalization
import SwiftUI
import TroveAPIClient


struct SavedCollectionSection: View {
    private struct Withdrawal {
        let collection: ParticipantCollectionState.Collection
        let session: KeycloakSessionSnapshot
    }

    @Environment(HealthDataModel.self) private var model
    @Environment(EnrollmentModel.self) private var enrollments
    @State private var withdrawal: Withdrawal?

    var body: some View {
        Section {
            if let collections = model.savedCollections.value {
                if collections.isEmpty { Text("No saved collection settings on this device.") }
                ForEach(collections) { collection in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title(for: collection)).font(.headline)
                        if let end = collection.plan.endsAt {
                            LabeledContent("Enrollment ends", value: end, format: .dateTime)
                        }
                        if isStopped(collection) {
                            Text("Collection has stopped on this device.").foregroundStyle(.secondary)
                        } else if collection.plan.endsAt.map({ $0 <= Date() }) == true {
                            Text("Enrollment has ended. Previously collected data can still be sent.").foregroundStyle(.secondary)
                        } else {
                            Text("Using your saved study settings.").foregroundStyle(.secondary)
                        }
                        Button(withdrawalTitle(for: collection), role: .destructive) {
                            guard let session = model.sessionSnapshot else {
                                return
                            }
                            withdrawal = Withdrawal(collection: collection, session: session)
                        }
                        .disabled(enrollments.isMutating || !model.savedCollections.isLoaded)
                    }
                }
            } else if model.savedCollections.error == nil {
                ProgressView("Loading saved settings…")
            }
            if model.savedCollections.error != nil {
                Text("Saved collection settings could not be loaded.").foregroundStyle(.secondary)
                Button("Retry") { Task { await model.refreshCollectionSettings() } }
            }
        } header: {
            Text("Saved Collection Settings")
        } footer: {
            Text("These settings are available offline. Withdrawal stops collection on this device before contacting the study.")
            Text("Other devices learn about withdrawal when they reconnect.")
        }
        .confirmationDialog(
            "Withdraw from this study?",
            isPresented: Binding(get: { withdrawal != nil }, set: { if !$0 { withdrawal = nil } }),
            titleVisibility: .visible
        ) {
            if let withdrawal {
                Button("Withdraw", role: .destructive) { performWithdrawal(withdrawal) }
            }
            Button("Cancel", role: .cancel) { withdrawal = nil }
        } message: {
            if let withdrawal {
                Text(title(for: withdrawal.collection))
                Text("You cannot enroll again after withdrawing. If you are offline, reconnect to confirm withdrawal with the study.")
            }
        }
    }

    private func withdrawalTitle(for collection: ParticipantCollectionState.Collection) -> LocalizedStringKey {
        isStopped(collection) ? "Confirm Withdrawal" : "Withdraw from Study"
    }

    private func title(for collection: ParticipantCollectionState.Collection) -> String {
        collection.plan.title[.currentOrDefault] ?? collection.plan.title.first?.value ?? String(localized: "Study")
    }

    private func isStopped(_ collection: ParticipantCollectionState.Collection) -> Bool {
        collection.isStopped || enrollments.isCollectionStopped(enrollmentId: collection.id)
    }

    private func performWithdrawal(_ selection: Withdrawal) {
        withdrawal = nil
        catchingTask {
            do {
                try await enrollments.withdrawSavedCollection(enrollmentId: selection.collection.id, for: selection.session)
            } catch {
                guard model.sessionSnapshot == selection.session else { throw CancellationError() }
                await model.refreshCollectionSettings()
                throw error
            }
            guard model.sessionSnapshot == selection.session else { throw CancellationError() }
            await model.run(.sync)
            await model.refreshCollectionSettings()
        }
    }
}
