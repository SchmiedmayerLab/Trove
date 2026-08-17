//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Grove
import SwiftUI
import TroveAPIClient


@Observable
final class BrowseModel: Module, EnvironmentAccessible {
    @ObservationIgnored @Dependency(TroveAPIModule.self) private var api

    private(set) var state: LoadingState<[Trove.Study]> = .idle
    private(set) var findState: LoadingState<[Trove.Study]> = .idle

    func refresh() async {
        state = .loading
        do {
            state = .loaded(try await api.requireClient().getParticipantStudies(.init(query: .init(studyId: nil))).ok.body.json)
        } catch {
            state = .failed(error)
        }
    }

    func find(studyId: String) async {
        findState = .loading
        do {
            findState = .loaded(try await api.requireClient().getParticipantStudies(.init(query: .init(studyId: studyId))).ok.body.json)
        } catch {
            findState = .failed(error)
        }
    }

    func resetFind() {
        findState = .idle
    }
}
