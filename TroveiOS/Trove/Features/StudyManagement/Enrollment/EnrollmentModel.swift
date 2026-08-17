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
final class EnrollmentModel: Module, EnvironmentAccessible {
    @ObservationIgnored @Dependency(TroveAPIModule.self) private var api

    private(set) var state: LoadingState<[Trove.Enrollment]> = .idle

    func refresh() async {
        state = .loading
        do {
            state = .loaded(try await api.requireClient().getParticipantEnrollments(.init()).ok.body.json)
        } catch {
            state = .failed(error)
        }
    }

    func enroll(studyId: String, invitationCode: String? = nil) async throws {
        _ = try await api.requireClient().postParticipantStudiesStudyIdEnrollments(
            .init(path: .init(studyId: studyId), body: .json(.init(invitationCode: invitationCode)))
        ).created.body.json
        await refresh()
    }

    func withdraw(enrollmentId: String) async throws {
        _ = try await api.requireClient().postParticipantEnrollmentsEnrollmentIdWithdraw(
            .init(path: .init(enrollmentId: enrollmentId))
        ).ok
        await refresh()
    }

    func activeEnrollment(forStudy studyId: String) -> Trove.Enrollment? {
        latestEnrollment(forStudy: studyId).flatMap { $0.withdrawnAt == nil ? $0 : nil }
    }

    func latestEnrollment(forStudy studyId: String) -> Trove.Enrollment? {
        guard let items = state.value else {
            return nil
        }
        return items
            .filter { $0.studyId == studyId }
            .max(by: { $0.enrolledAt < $1.enrolledAt })
    }
}
