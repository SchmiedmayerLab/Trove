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

    private var storedState: LoadingState<[Trove.Study]> = .idle
    private var storedFindState: LoadingState<[Trove.Study]> = .idle
    private var owner: KeycloakSessionSnapshot?
    private var refreshID: UUID?
    private var findID: UUID?

    var state: LoadingState<[Trove.Study]> {
        owner == api.sessionSnapshot ? storedState : .idle
    }

    var findState: LoadingState<[Trove.Study]> {
        owner == api.sessionSnapshot ? storedFindState : .idle
    }

    func invalidateSession() {
        storedState = .idle
        storedFindState = .idle
        refreshID = nil
        findID = nil
        owner = nil
    }

    private func currentSession() -> KeycloakSessionSnapshot? {
        let current = api.sessionSnapshot
        if owner != current {
            invalidateSession()
            owner = current
        }
        return current
    }

    func synchronizeSession() {
        _ = currentSession()
    }

    func refresh() async {
        guard let session = currentSession() else {
            return
        }
        let operation = UUID()
        refreshID = operation
        let hadValue = state.value != nil
        storedState.beginLoading()
        do {
            let studies = try await api.requireClient(for: session)
                .getParticipantStudies(.init(query: .init(studyId: nil)))
                .ok.body.json
            guard refreshID == operation, api.sessionSnapshot == session else {
                return
            }
            guard !Task.isCancelled else {
                storedState.cancelLoading()
                return
            }
            storedState.resolve(with: studies)
        } catch {
            guard refreshID == operation, api.sessionSnapshot == session else {
                return
            }
            if Task.isCancelled {
                storedState.cancelLoading()
            } else {
                storedState.reject(with: error)
                if hadValue {
                    ErrorHandler.shared.handle(error)
                }
            }
        }
    }

    func find(studyId: String) async {
        guard let session = currentSession() else {
            return
        }
        let operation = UUID()
        findID = operation
        storedFindState.beginLoading(preservingValue: false)
        do {
            let studies = try await api.requireClient(for: session)
                .getParticipantStudies(.init(query: .init(studyId: studyId)))
                .ok.body.json
            guard findID == operation, api.sessionSnapshot == session else {
                return
            }
            guard !Task.isCancelled else {
                storedFindState.cancelLoading()
                return
            }
            storedFindState.resolve(with: studies)
        } catch {
            guard findID == operation, api.sessionSnapshot == session else {
                return
            }
            if Task.isCancelled {
                storedFindState.cancelLoading()
            } else {
                storedFindState.reject(with: error)
            }
        }
    }

    func resetFind() {
        findID = nil
        storedFindState = .idle
    }
}
