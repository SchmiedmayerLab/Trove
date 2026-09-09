//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HealthKit
import XCTest
import XCTHealthKit


extension TroveUITests {
    /// Requires the owned two-study acquisition fixture and a fresh simulator.
    /// The host verifier checks database custody; the displayed status alone is not proof.
    @MainActor
    func testHealthKitSampleIsDeliveredAndNotRepeatedAfterRelaunch() async throws {
        let app = launchAndSignIn()
        for title in ["Restart Study A", "Restart Study B"] {
            XCTAssertTrue(app.buttons.matching(identifier: title).firstMatch.waitForExistence(timeout: 20))
        }
        app.tabBars.buttons["Health Data"].tap()
        let setup = app.buttons["Set Up This Device"]
        XCTAssertTrue(setup.wait(for: \.isEnabled, toEqual: true, timeout: 10))
        setup.tap()
        let reviewAccess = app.buttons["Review Health Access"]
        XCTAssertTrue(reviewAccess.wait(for: \.isEnabled, toEqual: true, timeout: 20))
        XCTAssertFalse(setup.isEnabled)
        reviewAccess.tap()
        app.handleHealthKitAuthorization(requireSheetToAppear: true)
        XCTAssertTrue(app.buttons["Sync Available Data"].wait(for: \.isEnabled, toEqual: true, timeout: 20))

        // Health's manual-entry UI records minutes, whereas consent uses microseconds.
        // Cross the next minute so this sample is strictly after the already accepted consent.
        // This is a data-time prerequisite, not a sleep to guess when the UI has finished.
        let now = Date().timeIntervalSince1970
        let nextMinute = (floor(now / 60) + 1) * 60 + 1
        try await Task.sleep(for: .seconds(nextMinute - now))
        try launchAndAddSample(.init(
            sampleType: .init(category: .heart, sampleType: HKQuantityType(.heartRate), healthAppDisplayTitle: "Heart Rate"),
            date: nil,
            enterSampleValueHandler: .enterSimpleNumericValue(73)
        ))
        // A fresh process has no earlier visible completion state. Delivery must be
        // started by launch/session restoration, without pressing the sync button.
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-authentication-state" }
        try restoreAndAwaitHealthData(app, attachmentName: "First HealthKit Delivery")
        app.terminate()
        try restoreAndAwaitHealthData(app, attachmentName: "HealthKit Delivery After Relaunch")
        app.terminate()
    }

    @MainActor
    private func restoreAndAwaitHealthData(_ app: XCUIApplication, attachmentName: String) throws {
        app.launch()
        XCTAssertTrue(app.navigationBars["Studies"].waitForExistence(timeout: 30))
        app.tabBars.buttons["Health Data"].tap()
        let finished = app.staticTexts["This sync pass finished. More data may be available; you can sync again."]
        let completed = finished.waitForExistence(timeout: 150)
        XCTAssertTrue(app.buttons["Sync Available Data"].wait(for: \.isEnabled, toEqual: true, timeout: 20))
        XCTAssertFalse(app.buttons["Set Up This Device"].isEnabled, "Relaunch must retain the existing source and checkpoint.")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = attachmentName
        screenshot.lifetime = .keepAlways
        add(screenshot)
        _ = try XCTUnwrap(completed ? finished : nil, "Acquisition and the full-validator delivery did not finish.")
    }
}
