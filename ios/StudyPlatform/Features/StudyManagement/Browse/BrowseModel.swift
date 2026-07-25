//
// This source file is part of the StudyPlatform-iOS open source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import SwiftUI
import Spezi
import StudyPlatformAPIClient

@Observable
final class BrowseModel: Module, EnvironmentAccessible {
    @ObservationIgnored
    @Dependency(StudyPlatformAPIModule.self) private var api

    private(set) var state: LoadingState<[StudyPlatform.Study]> = .idle
    private(set) var findState: LoadingState<[StudyPlatform.Study]> = .idle

    func refresh() async {
        state = .loading
        do {
            state = .loaded(try await api.client.getParticipantStudies(.init(query: .init(studyId: nil))).ok.body.json)
        } catch {
            state = .failed(error)
        }
    }

    func find(studyId: String) async {
        findState = .loading
        do {
            findState = .loaded(try await api.client.getParticipantStudies(.init(query: .init(studyId: studyId))).ok.body.json)
        } catch {
            findState = .failed(error)
        }
    }

    func resetFind() {
        findState = .idle
    }
}
