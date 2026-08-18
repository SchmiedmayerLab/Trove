//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import XCTest


final class TroveUITests: XCTestCase {
    private static let studyTitle = "Trove UI Test Study"

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        let readinessURL = try XCTUnwrap(URL(string: "http://127.0.0.1:8080/api/v0/groups"))
        let readinessResponse = try? await URLSession.shared.data(from: readinessURL).1 as? HTTPURLResponse
        try XCTSkipUnless(
            readinessResponse?.statusCode == 401,
            "The real-stack UI test runs only when the local protected API is available."
        )
    }

    @MainActor
    func testParticipantCanSignInEnrollAndWithdraw() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--reset-authentication-state")
        app.launchEnvironment["TROVE_API_BASE_URL"] = "http://127.0.0.1:8080/api/v0"
        app.launchEnvironment["TROVE_KEYCLOAK_ISSUER"] = "http://127.0.0.1:8180/realms/trove"
        app.launch()

        let signIn = app.buttons["Sign in with Keycloak"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 20), "The app did not present its Keycloak sign-in action.")
        signIn.tap()

        let authenticationSession = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let username = authenticationSession.textFields["Email"]
        XCTAssertTrue(username.waitForExistence(timeout: 20), "Keycloak did not present its username field.")
        username.tap()
        username.typeText("alice@example.com")

        let passwordField = authenticationSession.secureTextFields["Password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5), "Keycloak did not present its password field.")
        passwordField.tap()
        // Return submits the web form without relying on a button that the software keyboard can obscure.
        passwordField.typeText("password123\n") // Local development realm fixture; not a production credential.

        let studies = app.navigationBars["Studies"]
        XCTAssertTrue(studies.waitForExistence(timeout: 30), "The app did not reach the study list after sign-in.")

        let study = app.buttons.matching(identifier: Self.studyTitle).firstMatch
        XCTAssertTrue(study.waitForExistence(timeout: 20), "The seeded published study was not listed.")
        study.tap()

        let enroll = app.buttons["Enroll"]
        XCTAssertTrue(enroll.waitForExistence(timeout: 10), "The published study did not offer enrollment.")
        enroll.tap()
        let activeStatus = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Status, Active")
        ).firstMatch
        XCTAssertTrue(activeStatus.waitForExistence(timeout: 20), "Enrollment did not become active.")

        app.buttons["Withdraw from Study"].tap()
        let confirmWithdrawal = app.buttons["Withdraw"]
        XCTAssertTrue(confirmWithdrawal.waitForExistence(timeout: 5), "The withdrawal confirmation was not shown.")
        confirmWithdrawal.tap()
        let withdrawnStatus = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Status, Withdrawn")
        ).firstMatch
        XCTAssertTrue(withdrawnStatus.waitForExistence(timeout: 20), "Withdrawal was not reflected by the server.")
    }
}
