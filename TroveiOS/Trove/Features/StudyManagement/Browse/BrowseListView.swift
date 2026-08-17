//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import SwiftUI
import TroveAPITypes


struct BrowseListView: View {
    @Environment(BrowseModel.self) private var model

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let items):
                if items.isEmpty {
                    ContentUnavailableView(
                        "No Studies",
                        systemImage: "tray",
                        description: Text("No studies are currently available.")
                    )
                } else {
                    List(items, id: \.studyId) { item in
                        NavigationLink(value: item.studyId) {
                            BrowseRow(item: item)
                        }
                    }
                    .refreshable {
                        await model.refresh()
                    }
                    .navigationDestination(for: String.self) { studyId in
                        if let item = items.first(where: { $0.studyId == studyId }) {
                            EnrollmentView(item: item)
                        } else {
                            ContentUnavailableView("Study Unavailable", systemImage: "tray")
                        }
                    }
                }
            case .failed(let error):
                ProblemUnavailableView(title: "Could Not Load Studies", error: error) {
                    Task { await model.refresh() }
                }
            }
        }
        .task {
            if case .idle = model.state {
                await model.refresh()
            }
        }
    }
}
