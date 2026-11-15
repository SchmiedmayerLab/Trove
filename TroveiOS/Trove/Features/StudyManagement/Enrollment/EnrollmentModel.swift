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
        var stopCollection: @MainActor (KeycloakSessionSnapshot, String) async throws -> Void
        var stoppedEnrollments: @MainActor (KeycloakSessionSnapshot) async throws -> Set<String>
        var withdraw: @MainActor (KeycloakSessionSnapshot, String) async throws -> Trove.Enrollment
    }

    @ObservationIgnored @Dependency(TroveAPIModule.self) private var api
    @ObservationIgnored @Dependency(HealthDataModel.self) private var healthData
    @ObservationIgnored private let transport: Transport?

    private var storedState: LoadingState<[Trove.Enrollment]> = .idle
    private var storedCollectionStops: Set<String> = []
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
        storedCollectionStops = []
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
            let stopped: Set<String>
            if let transport {
                stopped = try await transport.stoppedEnrollments(session)
            } else {
                stopped = try await api.stoppedEnrollments(for: session)
            }
            guard isCurrent(session), refreshID == identifier else {
                return
            }
            guard !Task.isCancelled else {
                storedState.cancelLoading()
                return
            }
            storedCollectionStops = stopped
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
        try await withdraw(enrollmentId: enrollmentId, reloadServerState: false)
    }

    /// Saved settings permit a restrictive local stop even when profile/enrollment discovery is offline.
    /// Capture the presenting session so an old confirmation cannot affect a replacement account.
    func withdrawSavedCollection(enrollmentId: String, for captured: KeycloakSessionSnapshot) async throws {
        guard currentSession == captured else { throw CancellationError() }
        try await withdraw(enrollmentId: enrollmentId, reloadServerState: true)
    }

    func isCollectionStopped(enrollmentId: String) -> Bool {
        currentSession != nil && currentSession == storedSession && storedCollectionStops.contains(enrollmentId.lowercased())
    }

    private func withdraw(enrollmentId: String, reloadServerState: Bool) async throws {
        try await mutate(requiresLoadedState: !reloadServerState) { session in
            if let transport = self.transport {
                try await transport.stopCollection(session, enrollmentId)
            } else {
                try await self.healthData.stopCollection(enrollmentId: enrollmentId, for: session)
            }
            guard self.isCurrent(session) else { throw CancellationError() }
            self.storedCollectionStops.insert(enrollmentId.lowercased())
            if reloadServerState, let completed = try await self.confirmExistingWithdrawal(enrollmentId: enrollmentId, for: session) {
                return completed
            }
            try Task.checkCancellation()
            if let transport = self.transport {
                return try await transport.withdraw(session, enrollmentId)
            }
            return try await self.api.requireClient(for: session).postParticipantEnrollmentsEnrollmentIdWithdraw(
                .init(path: .init(enrollmentId: enrollmentId))
            ).ok.body.json
        }
    }

    /// A lost withdrawal response must not trap retries in an "already withdrawn" conflict.
    private func confirmExistingWithdrawal(enrollmentId: String, for session: KeycloakSessionSnapshot) async throws -> Trove.Enrollment? {
        let values: [Trove.Enrollment]
        if let transport { values = try await transport.list(session) } else {
            values = try await api.requireClient(for: session).getParticipantEnrollments(.init()).ok.body.json
        }
        guard isCurrent(session) else { throw CancellationError() }
        guard let enrollment = values.first(where: { $0.id.lowercased() == enrollmentId.lowercased() }) else {
            throw EnrollmentModelError.enrollmentStateUnavailable
        }
        storedState.resolve(with: values)
        return enrollment.withdrawnAt == nil ? nil : enrollment
    }

    func isWithdrawalPending(for enrollment: Trove.Enrollment) -> Bool {
        currentSession != nil && currentSession == storedSession && enrollment.withdrawnAt == nil
            && storedCollectionStops.contains(enrollment.id.lowercased())
    }

    func activeEnrollment(forStudy studyId: String) -> Trove.Enrollment? {
        latestEnrollment(forStudy: studyId).flatMap {
            $0.withdrawnAt == nil && ($0.endsAt.map { Date() < $0 } ?? true) ? $0 : nil
        }
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

    private func mutate(
        requiresLoadedState: Bool = true, _ operation: @MainActor (KeycloakSessionSnapshot) async throws -> Trove.Enrollment
    ) async throws {
        guard let session = synchronizeSession(),
              !requiresLoadedState || storedState.value != nil && (storedState.isLoaded || storedState.isLoading) else {
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
