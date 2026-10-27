import XCTest

final class TossUITests: XCTestCase {
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-isolated"] + arguments
        app.launch()
        return app
    }

    func testOnboardingAndPrimaryNavigation() throws {
        let app = launch(["--uitest-reset-onboarding"])
        XCTAssertTrue(app.buttons["Get Started"].waitForExistence(timeout: 15))
        app.buttons["Get Started"].tap()
        XCTAssertTrue(app.staticTexts["Pick up where you left off."].exists)
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["It understands what you send."].exists)
        app.buttons["Continue"].tap()
        app.buttons["Set up later"].tap()
        XCTAssertTrue(app.buttons["Inbox"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Connect a Device"].exists)
        app.buttons["Send"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Send something"].exists)
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Privacy"].exists)
        XCTAssertTrue(app.staticTexts["Paired devices must use the same iCloud account for delivery when apart."].exists)
    }

    func testSaveForLaterKeepsContentAndResetsDraft() throws {
        let app = launch()
        app.buttons["Send"].firstMatch.tap()
        let draft = app.textFields["send-draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        draft.tap()
        draft.typeText("A useful note to keep")
        app.buttons["Done"].tap()
        app.swipeUp()
        let save = app.buttons["Save for Later on This Device"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["Saved for Later on this device"].waitForExistence(timeout: 5))
        app.buttons["View Later"].tap()
        XCTAssertTrue(app.staticTexts["A useful note to keep"].waitForExistence(timeout: 5))
    }

    func testFailedTransferHasRecoveryAndUpdatesWithoutReopening() throws {
        let app = launch(["--uitest-transfers"])
        let history = app.buttons["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.tap()
        app.staticTexts["A note for my Mac"].tap()
        XCTAssertTrue(app.staticTexts["iCloud storage is full"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Free up space in iCloud")).firstMatch.exists)
        attachScreenshot("Failure guidance")
        app.buttons["Try Again"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Queued for My MacBook"].waitForExistence(timeout: 5))
        attachScreenshot("Transfer recovery")
    }

    func testMissingPreviewShowsRecoveryInsteadOfSpinning() throws {
        let app = launch(["--uitest-transfers"])
        let item = app.staticTexts["Missing preview.pdf"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(app.staticTexts["Couldn't open this file"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Try Again"].exists)
        attachScreenshot("Missing file recovery")
    }

    func testInvalidPairingLinkExplainsNextStep() throws {
        let app = launch()
        app.buttons["Connect a Device"].tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if system.alerts.firstMatch.waitForExistence(timeout: 5) {
            let allow = system.alerts.buttons["Allow"]
            if allow.exists { allow.tap() }
            else { system.alerts.buttons.firstMatch.tap() }
        }
        let paste = app.buttons["Paste Pairing Link"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        let field = app.alerts.textFields.firstMatch
        if !field.waitForExistence(timeout: 3) { paste.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap(); field.typeText("not-a-toss-link")
        app.alerts.buttons["Review Code"].tap()
        XCTAssertTrue(app.staticTexts["This isn't a valid, current Toss code. Choose New Code on your Mac and try again."].waitForExistence(timeout: 5))
        attachScreenshot("Pairing recovery")
    }

    func testSendActionsRemainReachableAtLargestTextSize() throws {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.buttons["Send"].firstMatch.tap()
        let draft = app.textFields["send-draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        draft.tap(); draft.typeText("A larger text note")
        app.buttons["Done"].tap()
        let save = app.buttons["Save for Later on This Device"]
        for _ in 0..<5 {
            if save.exists && save.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(save.isHittable)
        XCTAssertTrue(save.isEnabled)
        attachScreenshot("Largest text size")
    }

    func testLandscapeSendNavigation() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch()
        app.buttons["Send"].firstMatch.tap()
        XCTAssertTrue(app.textFields["send-draft"].waitForExistence(timeout: 5))
        let connect = app.buttons["Connect a Device"]
        for _ in 0..<4 {
            if connect.exists && connect.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(connect.isHittable)
        attachScreenshot("Landscape Send")
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
