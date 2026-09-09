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
    /// A bounded transport seam; production requests use a client bound to the captured session.
    struct Transport {
        var session: @MainActor () -> KeycloakSessionSnapshot?
        var list: @MainActor (KeycloakSessionSnapshot) async throws -> [Trove.Enrollment]
        var enroll: @MainActor (KeycloakSessionSnapshot, String, String?) async throws -> Trove.Enrollment
        var withdraw: @MainActor (KeycloakSessionSnapshot, String) async throws -> Trove.Enrollment
    }

    @ObservationIgnored @Dependency(TroveAPIModule.self) private var api
    @ObservationIgnored private let transport: Transport?

    private var storedState: LoadingState<[Trove.Enrollment]> = .idle
    private var storedSession: KeycloakSessionSnapshot?
    private var refreshID: UUID?
    private var mutationID: UUID?

    var state: LoadingState<[Trove.Enrollment]> {
        currentSession != nil && currentSession == storedSession ? storedState : .idle
    }

    var isMutating: Bool {
        currentSession != nil && currentSession == storedSession && mutationID != nil
    }

    private var currentSession: KeycloakSessionSnapshot? {
        if let transport {
            return transport.session()
        }
        return api.sessionSnapshot
    }

    init(transport: Transport? = nil) {
        self.transport = transport
    }

    /// Also checked on every read, so delayed view callbacks cannot expose the prior account's state.
    func invalidateSession() {
        storedState = .idle
        storedSession = nil
        refreshID = nil
        mutationID = nil
    }

    func refresh() async {
        guard let session = synchronizeSession(), mutationID == nil else {
            return
        }
        let identifier = UUID()
        refreshID = identifier
        let hadValue = storedState.value != nil
        storedState.beginLoading()
        defer {
            if refreshID == identifier { refreshID = nil }
        }
        do {
            let enrollments: [Trove.Enrollment]
            if let transport {
                enrollments = try await transport.list(session)
            } else {
                enrollments = try await api.requireClient(for: session).getParticipantEnrollments(.init()).ok.body.json
            }
            guard isCurrent(session), refreshID == identifier else {
                return
            }
            guard !Task.isCancelled else {
                storedState.cancelLoading()
                return
            }
            storedState.resolve(with: enrollments)
        } catch {
            guard isCurrent(session), refreshID == identifier else {
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

    func enroll(studyId: String, invitationCode: String? = nil) async throws {
        try await mutate { session in
            if let transport = self.transport {
                return try await transport.enroll(session, studyId, invitationCode)
            }
            return try await self.api.requireClient(for: session).postParticipantStudiesStudyIdEnrollments(
                .init(path: .init(studyId: studyId), body: .json(.init(invitationCode: invitationCode)))
            ).created.body.json
        }
    }

    func withdraw(enrollmentId: String) async throws {
        try await mutate { session in
            if let transport = self.transport {
                return try await transport.withdraw(session, enrollmentId)
            }
            return try await self.api.requireClient(for: session).postParticipantEnrollmentsEnrollmentIdWithdraw(
                .init(path: .init(enrollmentId: enrollmentId))
            ).ok.body.json
        }
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
        var items = storedState.value ?? []
        if let index = items.firstIndex(where: { $0.id == enrollment.id }) {
            items[index] = enrollment
        } else {
            items.append(enrollment)
        }
        storedState.resolve(with: items)
    }

    @discardableResult
    func synchronizeSession() -> KeycloakSessionSnapshot? {
        let session = currentSession
        if session != storedSession {
            invalidateSession()
            storedSession = session
        }
        return session
    }

    private func isCurrent(_ session: KeycloakSessionSnapshot) -> Bool {
        currentSession == session && storedSession == session
    }

    private func mutate(_ operation: @MainActor (KeycloakSessionSnapshot) async throws -> Trove.Enrollment) async throws {
        guard let session = synchronizeSession(), storedState.value != nil,
              storedState.isLoaded || storedState.isLoading else {
            throw EnrollmentModelError.enrollmentStateUnavailable
        }
        guard mutationID == nil else {
            throw EnrollmentModelError.mutationInProgress
        }
        let identifier = UUID()
        mutationID = identifier
        refreshID = nil
        storedState.cancelLoading()
        defer {
            if mutationID == identifier { mutationID = nil }
        }
        do {
            try Task.checkCancellation()
            let enrollment = try await operation(session)
            guard isCurrent(session), mutationID == identifier else {
                throw CancellationError()
            }
            // A received server result remains authoritative even if the view task was cancelled.
            store(enrollment)
        } catch {
            guard isCurrent(session), mutationID == identifier else {
                throw CancellationError()
            }
            storedState.reject(with: error)
            throw error
        }
    }
}
