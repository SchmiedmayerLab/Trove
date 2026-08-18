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


enum EnrollmentModelError: LocalizedError {
    case enrollmentStateUnavailable
    case mutationInProgress

    var errorDescription: String? {
        switch self {
        case .enrollmentStateUnavailable:
            String(
                localized: "Enrollment status must be loaded before it can be changed.",
                comment: "Error shown when an enrollment change is attempted before its current status is available."
            )
        case .mutationInProgress:
            String(
                localized: "Another enrollment change is already in progress.",
                comment: "Error shown when an enrollment change is attempted while another change is still running."
            )
        }
    }
}


@MainActor
@Observable
final class EnrollmentModel: Module, EnvironmentAccessible {
    @ObservationIgnored @Dependency(TroveAPIModule.self) private var api

    private(set) var state: LoadingState<[Trove.Enrollment]> = .idle
    private(set) var isMutating = false

    func refresh() async {
        let hadValue = state.value != nil
        state.beginLoading()
        do {
            let enrollments = try await api.requireClient().getParticipantEnrollments(.init()).ok.body.json
            guard !Task.isCancelled else {
                state.cancelLoading()
                return
            }
            state.resolve(with: enrollments)
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

    func enroll(studyId: String, invitationCode: String? = nil) async throws {
        guard state.isLoaded else {
            throw EnrollmentModelError.enrollmentStateUnavailable
        }
        guard !isMutating else {
            throw EnrollmentModelError.mutationInProgress
        }
        isMutating = true
        defer { isMutating = false }

        let enrollment = try await api.requireClient().postParticipantStudiesStudyIdEnrollments(
            .init(path: .init(studyId: studyId), body: .json(.init(invitationCode: invitationCode)))
        ).created.body.json
        store(enrollment)
    }

    func withdraw(enrollmentId: String) async throws {
        guard state.isLoaded else {
            throw EnrollmentModelError.enrollmentStateUnavailable
        }
        guard !isMutating else {
            throw EnrollmentModelError.mutationInProgress
        }
        isMutating = true
        defer { isMutating = false }

        let enrollment = try await api.requireClient().postParticipantEnrollmentsEnrollmentIdWithdraw(
            .init(path: .init(enrollmentId: enrollmentId))
        ).ok.body.json
        store(enrollment)
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

    private func store(_ enrollment: Trove.Enrollment) {
        var items = state.value ?? []
        if let index = items.firstIndex(where: { $0.id == enrollment.id }) {
            items[index] = enrollment
        } else {
            items.append(enrollment)
        }
        state.resolve(with: items)
    }
}
