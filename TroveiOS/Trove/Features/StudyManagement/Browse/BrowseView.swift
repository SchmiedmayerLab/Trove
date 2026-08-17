//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveAccount
import SwiftUI


struct BrowseView: View {
    @Environment(Account.self) private var account: Account?

    @State private var isPresentingFindStudy = false
    @State private var isPresentingAccount = false

    var body: some View {
        NavigationStack {
            BrowseListView()
                .navigationTitle("Studies")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Find Study", systemImage: "magnifyingglass") {
                            isPresentingFindStudy = true
                        }
                    }
                    if account != nil {
                        ToolbarItem(placement: .topBarTrailing) {
                            AccountButton(isPresented: $isPresentingAccount)
                        }
                    }
                }
                .sheet(isPresented: $isPresentingFindStudy) {
                    BrowseFindView()
                }
                .sheet(isPresented: $isPresentingAccount) {
                    AccountSheet()
                }
        }
    }
}
