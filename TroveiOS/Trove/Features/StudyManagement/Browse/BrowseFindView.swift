//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import SwiftUI


struct BrowseFindView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(BrowseModel.self) private var model

    @State private var studyId: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Study ID (UUID)", text: $studyId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { search() }
                    Button("Search") { search() }
                        .disabled(!isValidUUID || model.findState.isLoading)
                } footer: {
                    Text("Enter a study ID to find a private (unlisted) study.")
                }

                resultsSection
            }
            .navigationTitle("Find Study")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        model.resetFind()
                        dismiss()
                    }
                }
            }
            .onDisappear { model.resetFind() }
        }
    }

    @ViewBuilder private var resultsSection: some View {
        switch model.findState {
        case .idle, .loading:
            EmptyView()
        case .loaded(let results) where results.isEmpty:
            Section {
                ContentUnavailableView(
                    "No Study Found",
                    systemImage: "questionmark.circle",
                    description: Text("No study with that ID is available to you.")
                )
            }
        case .loaded(let results):
            Section("Results") {
                ForEach(results, id: \.studyId) { item in
                    NavigationLink {
                        EnrollmentView(item: item)
                    } label: {
                        BrowseRow(item: item)
                    }
                }
            }
        case .failed(let error, _):
            Section {
                ProblemUnavailableView(title: "Could Not Find Study", error: error, retry: search)
            }
        }
    }

    private var isValidUUID: Bool {
        UUID(uuidString: studyId.trimmingCharacters(in: .whitespaces)) != nil
    }

    private func search() {
        guard isValidUUID else {
            return
        }
        let value = studyId.trimmingCharacters(in: .whitespaces)
        catchingTask { await model.find(studyId: value) }
    }
}
