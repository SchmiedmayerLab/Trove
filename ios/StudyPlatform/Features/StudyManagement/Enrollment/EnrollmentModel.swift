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
final class EnrollmentModel: Module, EnvironmentAccessible {
    @ObservationIgnored
    @Dependency(StudyPlatformAPIModule.self) private var api

    private(set) var state: LoadingState<[StudyPlatform.Enrollment]> = .idle

    func refresh() async {
        state = .loading
        do {
            state = .loaded(try await api.client.getParticipantEnrollments(.init()).ok.body.json)
        } catch {
            state = .failed(error)
        }
    }

    func enroll(studyId: String, invitationCode: String? = nil) async throws {
        _ = try await api.client.postParticipantStudiesStudyIdEnrollments(
            .init(path: .init(studyId: studyId), body: .json(.init(invitationCode: invitationCode)))
        ).created.body.json
        await refresh()
    }

    func withdraw(enrollmentId: String) async throws {
        _ = try await api.client.postParticipantEnrollmentsEnrollmentIdWithdraw(
            .init(path: .init(enrollmentId: enrollmentId))
        ).ok
        await refresh()
    }

    func activeEnrollment(forStudy studyId: String) -> StudyPlatform.Enrollment? {
        latestEnrollment(forStudy: studyId).flatMap { $0.withdrawnAt == nil ? $0 : nil }
    }

    func latestEnrollment(forStudy studyId: String) -> StudyPlatform.Enrollment? {
        guard let items = state.value else { return nil }
        return items
            .filter { $0.studyId == studyId }
            .max(by: { $0.enrolledAt < $1.enrolledAt })
    }
}
