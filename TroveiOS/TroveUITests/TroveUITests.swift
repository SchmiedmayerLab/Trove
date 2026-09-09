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
    private static let authenticationTimeout: TimeInterval = 60

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
    func launchAndSignIn() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("--reset-authentication-state")
        app.launchEnvironment["TROVE_API_BASE_URL"] = "http://127.0.0.1:8080/api/v0"
        app.launchEnvironment["TROVE_KEYCLOAK_ISSUER"] = "http://localhost:8180/realms/trove"
        app.launch()

        let signIn = app.buttons["Sign in with Keycloak"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 20), "The app did not present its Keycloak sign-in action.")
        signIn.tap()

        let authenticationSession = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        XCTAssertTrue(
            authenticationSession.wait(for: .runningForeground, timeout: Self.authenticationTimeout),
            "The authentication session did not enter the foreground."
        )
        let username = authenticationSession.textFields["Email"]
        XCTAssertTrue(
            username.waitForExistence(timeout: Self.authenticationTimeout),
            "Keycloak did not present its username field."
        )
        username.tap()
        username.typeText("alice@example.com")

        let passwordField = authenticationSession.secureTextFields["Password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5), "Keycloak did not present its password field.")
        passwordField.tap()
        // Return submits the web form without relying on a button that the software keyboard can obscure.
        passwordField.typeText("password123\n") // Local development realm fixture; not a production credential.

        let studies = app.navigationBars["Studies"]
        XCTAssertTrue(studies.waitForExistence(timeout: 30), "The app did not reach the study list after sign-in.")
        return app
    }

    @MainActor
    func testParticipantCanSignInEnrollAndWithdraw() async throws {
        let app = launchAndSignIn()

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

        reviewAndSubmitConsent(app)
        verifyHealthDataSetup(app, create: true)
        try await reviewAndAdoptRevision(app)
        verifyHealthDataSetup(app, create: false)

        if !app.buttons["Withdraw from Study"].isHittable { app.swipeUp() }
        app.buttons["Withdraw from Study"].tap()
        let confirmWithdrawal = app.buttons["Withdraw"]
        XCTAssertTrue(confirmWithdrawal.waitForExistence(timeout: 5), "The withdrawal confirmation was not shown.")
        confirmWithdrawal.tap()
        let withdrawnStatus = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Status, Withdrawn")
        ).firstMatch
        XCTAssertTrue(withdrawnStatus.waitForExistence(timeout: 20), "Withdrawal was not reflected by the server.")

        verifyRestoredWithdrawal(app)
    }

    @MainActor
    private func verifyHealthDataSetup(_ app: XCUIApplication, create: Bool) {
        app.tabBars.buttons["Health Data"].tap()
        let setup = app.buttons["Set Up This Device"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        if create {
            XCTAssertTrue(setup.wait(for: \.isEnabled, toEqual: true, timeout: 10))
            setup.tap()
        }
        // Foreground collection may advance a restored source to its Health access gate.
        // Both states require an existing registration; error and revoked states do not qualify.
        let ready = app.staticTexts.matching(NSPredicate(format: "label IN %@", [
            "This device is set up. You can review Health access and sync available data.",
            "Review Health access before syncing data from this device."
        ])).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 20), "The real participant source did not register or restore.")
        XCTAssertFalse(setup.isEnabled, "Restoration must not offer replacement registration.")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = create ? "Health Data Setup" : "Health Data Restored"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.tabBars.buttons["Studies"].tap()
    }

    @MainActor
    private func reviewAndSubmitConsent(_ app: XCUIApplication, revision: Int = 1) {
        let review = app.buttons[revision == 1 ? "Review Consent" : "Review Revision \(revision)"]
        if !review.isHittable { app.swipeUp() }
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        review.tap()
        let agree = app.switches["ConsentForm:agree"]
        XCTAssertTrue(agree.waitForExistence(timeout: 20), "The exact consent presentation did not load.")
        XCTAssertTrue(app.staticTexts["Revision \(revision)"].exists)
        agree.tap()
        let firstName = app.textFields["Enter your first name…"]
        XCTAssertTrue(firstName.waitForExistence(timeout: 5))
        firstName.tap()
        firstName.typeText("Alice")
        let lastName = app.textFields["Enter your last name…"]
        lastName.tap()
        lastName.typeText("Participant\n")
        let signature = app.scrollViews["Signature Field"]
        XCTAssertTrue(signature.waitForExistence(timeout: 5))
        signature.swipeRight()
        let submit = app.buttons["Submit Consent"]
        if !submit.isHittable { app.swipeUp() }
        XCTAssertTrue(submit.isEnabled, "Real consent controls did not become complete.")
        submit.tap()
        XCTAssertTrue(app.staticTexts["Consent Recorded"].waitForExistence(timeout: 30), "Consent acceptance was not confirmed.")
        app.buttons["Done"].tap()
    }

    @MainActor
    private func reviewAndAdoptRevision(_ app: XCUIApplication) async throws {
        try await StudyRevisionFixture.publishSecondRevision(studyTitle: Self.studyTitle)
        reopenStudy(app)
        let currentRevision = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Current revision, 1")).firstMatch
        XCTAssertTrue(currentRevision.waitForExistence(timeout: 10), "Publication must not automatically advance enrollment.")
        let review = app.buttons["Review Revision 2"]
        if !review.isHittable { app.swipeUp() }
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        review.tap()
        XCTAssertTrue(app.staticTexts["Study Consent — Revision 2"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Submitting this consent will update your enrollment to revision 2."].exists)
        app.buttons["Done"].tap()
        if !currentRevision.exists { app.swipeDown() }
        XCTAssertTrue(currentRevision.exists, "Dismissing a review must not adopt its revision.")
        reviewAndSubmitConsent(app, revision: 2)
        let adoptedRevision = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Current revision, 2")).firstMatch
        if !adoptedRevision.exists { app.swipeDown() }
        XCTAssertTrue(adoptedRevision.waitForExistence(timeout: 20), "Accepted consent did not advance the displayed enrollment revision.")
        XCTAssertFalse(app.buttons["Review Revision 2"].exists, "An adopted revision must no longer be offered as an update.")
    }

    @MainActor
    private func reopenStudy(_ app: XCUIApplication) {
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-authentication-state" }
        app.launch()
        let studies = app.navigationBars["Studies"]
        XCTAssertTrue(studies.waitForExistence(timeout: 30), "The app did not restore its authenticated session after restart.")
        let study = app.buttons.matching(identifier: Self.studyTitle).firstMatch
        XCTAssertTrue(study.waitForExistence(timeout: 20), "The study list did not reload for the restored session.")
        study.tap()
    }

    @MainActor
    private func verifyRestoredWithdrawal(_ app: XCUIApplication) {
        reopenStudy(app)
        let withdrawnStatus = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Status, Withdrawn")
        ).firstMatch
        XCTAssertTrue(withdrawnStatus.waitForExistence(timeout: 20), "Restart did not restore the server's withdrawn enrollment state.")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Current revision, 2")).firstMatch.exists)
        let review = app.buttons["Review Consent"]
        // Form rows below the viewport are materialized when scrolled into view.
        if !review.isHittable { app.swipeUp() }
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        review.tap()
        XCTAssertTrue(
            app.staticTexts["Consent Recorded"].waitForExistence(timeout: 20),
            "Restart did not restore the existing consent receipt after withdrawal."
        )
        XCTAssertFalse(app.buttons["Submit Consent"].exists, "A historical receipt must not create a new consent submission.")
        XCTAssertTrue(app.staticTexts["Revision 2"].exists, "Restoration must identify the adopted revision's receipt.")
        app.buttons["Done"].tap()
        if !withdrawnStatus.exists { app.swipeDown() }
        XCTAssertTrue(withdrawnStatus.exists, "Restoring a receipt must not reactivate enrollment.")
    }
}
