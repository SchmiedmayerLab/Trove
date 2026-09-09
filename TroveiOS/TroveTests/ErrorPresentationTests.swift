//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import OpenAPIRuntime
import Testing
@testable import Trove


@MainActor
struct ErrorPresentationTests {
    private struct UntrustedLocalizedError: LocalizedError {
        var errorDescription: String? { "Bearer PRIVATE-TOKEN; PDF SIGNATURE; participant-secret" }
    }

    @Test
    func unknownLocalizedErrorAndProviderPayloadAreNeverDisplayed() throws {
        let errors: [any Error] = [
            UntrustedLocalizedError(),
            NSError(domain: "OAuth", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "PRIVATE-TOKEN PDF SIGNATURE participant-secret",
                NSUnderlyingErrorKey: UntrustedLocalizedError()
            ]),
            Self.clientError(underlying: UntrustedLocalizedError())
        ]
        for error in errors {
            let handler = ErrorHandler()
            handler.handle(error)
            #expect(handler.currentError == .unexpectedFailure)
            let presentation = try #require(handler.currentError)
            let text = String(localized: presentation.message)
            for sentinel in ["PRIVATE-TOKEN", "PDF", "SIGNATURE", "participant-secret"] {
                #expect(!text.contains(sentinel))
                #expect(!String(describing: presentation).contains(sentinel))
            }
        }
    }

    @Test
    func reviewedAccountAndEnrollmentMessagesArePreservedWithoutUnderlyingPayloads() {
        #expect(ErrorPresentation(EnrollmentModelError.enrollmentStateUnavailable) == .enrollmentUnavailable)
        #expect(ErrorPresentation(EnrollmentModelError.mutationInProgress) == .enrollmentMutationInProgress)
        #expect(ErrorPresentation(TroveAccountError.profileUpdateFailed(underlying: UntrustedLocalizedError())) == .profileUpdateFailed)
        #expect(ErrorPresentation(TroveAccountError.profileFetchFailed(underlying: UntrustedLocalizedError())) == .profileFetchFailed)
        #expect(ErrorPresentation(KeycloakAccountError.notSignedIn) == .notSignedIn)
        #expect(ErrorPresentation(KeycloakAccountError.authenticationFailed) == .authenticationFailed)
        #expect(ErrorPresentation(URLError(.notConnectedToInternet)) == .networkUnavailable)
    }

    @Test(arguments: [0, 1, 6])
    func cancellationIsSilentThroughKnownWrappers(depth: Int) {
        var error: any Error = CancellationError()
        for _ in 0..<depth {
            error = Self.clientError(underlying: error)
        }
        let handler = ErrorHandler()
        handler.handle(error)
        #expect(handler.currentError == nil)
        handler.currentError = .profileFetchFailed
        handler.handle(TroveAccountError.profileUpdateFailed(underlying: URLError(.cancelled)))
        #expect(handler.currentError == .profileFetchFailed)
        #expect(ErrorPresentation(NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: error])) == nil)
    }

    @Test
    func deeplyNestedUntrustedErrorsHaveBoundedInspection() {
        var error: any Error = UntrustedLocalizedError()
        for _ in 0..<32 {
            error = Self.clientError(underlying: error)
        }
        #expect(ErrorPresentation(error) == .unexpectedFailure)
    }

    @Test
    func cancelledTaskCannotPublishAnAlert() async {
        let handler = ErrorHandler()
        let task = Task { handler.handle(UntrustedLocalizedError()) }
        task.cancel()
        await task.value
        #expect(handler.currentError == nil)
    }
}


extension ErrorPresentationTests {
    private static func clientError(underlying: any Error) -> ClientError {
        ClientError(
            operationID: "private-operation",
            operationInput: "PRIVATE-TOKEN PDF SIGNATURE participant-secret",
            requestBody: HTTPBody("PRIVATE-TOKEN PDF SIGNATURE participant-secret"),
            responseBody: HTTPBody("PRIVATE-TOKEN PDF SIGNATURE participant-secret"),
            causeDescription: "PRIVATE-TOKEN PDF SIGNATURE participant-secret",
            underlyingError: underlying
        )
    }
}
