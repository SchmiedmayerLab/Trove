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


@MainActor
@Observable
final class BrowseModel: Module, EnvironmentAccessible {
    @ObservationIgnored @Dependency(TroveAPIModule.self) private var api

    private(set) var state: LoadingState<[Trove.Study]> = .idle
    private(set) var findState: LoadingState<[Trove.Study]> = .idle

    func refresh() async {
        let hadValue = state.value != nil
        state.beginLoading()
        do {
            let studies = try await api.requireClient()
                .getParticipantStudies(.init(query: .init(studyId: nil)))
                .ok.body.json
            guard !Task.isCancelled else {
                state.cancelLoading()
                return
            }
            state.resolve(with: studies)
        } catch {
            if Task.isCancelled {
                state.cancelLoading()
            } else {
                state.reject(with: error)
                if hadValue {
                    ErrorHandler.shared.handle(error)
                }
            }
        }
    }

    func find(studyId: String) async {
        findState.beginLoading(preservingValue: false)
        do {
            let studies = try await api.requireClient()
                .getParticipantStudies(.init(query: .init(studyId: studyId)))
                .ok.body.json
            guard !Task.isCancelled else {
                findState.cancelLoading()
                return
            }
            findState.resolve(with: studies)
        } catch {
            if Task.isCancelled {
                findState.cancelLoading()
            } else {
                findState.reject(with: error)
            }
        }
    }

    func resetFind() {
        findState = .idle
    }
}
