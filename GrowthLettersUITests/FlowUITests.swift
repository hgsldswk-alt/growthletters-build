import XCTest

final class FlowUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testFirstOpenWritesInTwoTapsAndReadsInTwo() {
        let app = launch()
        let message = ProcessInfo.processInfo.environment["GL_MULTILINE_TEST"] ?? "You found a yellow leaf.\nWe kept it by the window."
        write(message, in: app)
        wait(element(app, "notice.status"))
        tap(element(app, "tab.letters"))
        tap(firstLetter(app))
        wait(element(app, "read.body"))
        XCTAssertTrue(element(app, "read.body").label.contains("yellow leaf") ||
                      element(app, "read.body").label.contains(message.split(separator: "\n").first.map(String.init) ?? message))
    }

    func testPhotoAndNotificationDenialLeaveWritingAvailable() {
        let app = launch("-seed", "-photo-failure", "-notification-denied")
        tap(element(app, "write.photo"))
        tap(app.alerts.firstMatch.descendants(matching: .any).matching(identifier: "OK").firstMatch)
        write("Words without a photo.", in: app)
        tap(element(app, "write.reminder"))
        tap(element(app, "reminder.save"), in: app)
        tap(app.alerts.firstMatch.descendants(matching: .any).matching(identifier: "OK").firstMatch)
        tap(element(app, "tab.letters"))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Open on")).firstMatch.exists)
        tap(element(app, "tab.write"))
        wait(element(app, "letter.body"))
    }

    func testChildSwitchAndDraftRelaunch() {
        let id = UUID().uuidString
        let app = launch("-seed", id: id)
        tap(element(app, "letter.body"))
        element(app, "letter.body").typeText("Mia draft")
        tap(element(app, "child.1"))
        XCTAssertFalse((element(app, "letter.body").value as? String ?? "").contains("Mia draft"))
        element(app, "letter.body").typeText("Theo draft")
        tap(element(app, "child.0"))
        XCTAssertTrue((element(app, "letter.body").value as? String ?? "").contains("Mia draft"))
        XCUIDevice.shared.press(.home)
        app.activate()
        app.terminate()
        let reopened = launch("-seed", id: id, reset: false)
        XCTAssertTrue((element(reopened, "letter.body").value as? String ?? "").contains("Mia draft"))
        tap(element(reopened, "child.1"))
        XCTAssertTrue((element(reopened, "letter.body").value as? String ?? "").contains("Theo draft"))
    }

    func testOverflowChildWritesInTwoTapsAndTabsStayHittable() {
        let app = launch("-seed", "-many-children")
        let choices = element(app, "child.choices")
        wait(choices)
        let child = element(app, "child.6")
        for _ in 0..<5 where !child.isHittable { choices.swipeLeft() }
        assertTouchTarget(child)
        tap(child)
        wait(app.keyboards.firstMatch)
        let editor = element(app, "letter.body")
        editor.typeText("For Zoe, with love.")
        for key in ["tab.letters", "tab.receive", "write.save"] { assertTouchTarget(element(app, key)) }
        tap(element(app, "write.save"))
        wait(element(app, "notice.status"))
        tap(editor, in: app)
        wait(app.keyboards.firstMatch)
        tap(element(app, "tab.receive"))
        wait(element(app, "import.paste"))
    }

    func testEditChildAndBirthdayBrowsing() {
        let app = launch("-seed")
        tap(element(app, "tab.letters"))
        wait(element(app, "folder.age"))
        XCTAssertTrue(element(app, "folder.age").label.contains("2") && element(app, "folder.age").label.contains("3"))
        tap(element(app, "child.edit"))
        let field = element(app, "child.nickname")
        wait(field)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "Mimi")
        tap(element(app, "child.save"), in: app)
        wait(element(app, "child.0"))
        XCTAssertTrue(element(app, "child.0").label.contains("Mimi"))
        tap(element(app, "child.edit"))
        tap(element(app, "child.clearBirthday"), in: app)
        tap(element(app, "child.save"), in: app)
        XCTAssertFalse(element(app, "folder.age").exists)
    }

    func testBookPreviewPDFAndPageImages() {
        let app = launch("-seed")
        tap(element(app, "write.recent.book"), in: app)
        wait(element(app, "book.page"))
        tap(element(app, "book.next"), in: app)
        XCTAssertTrue(element(app, "book.page").label.contains("2"))
        tap(element(app, "book.pdf"), in: app)
        wait(element(app, "share.requested"))
        tap(element(app, "book.images"), in: app)
        wait(element(app, "share.requested"))
    }

    func testNoBirthdayCanBeAddedFromHomeInThreeTapsAndRefreshesHistory() {
        let app = launch("-seed", "-no-birthday")
        XCTAssertFalse(element(app, "letter.age").exists)
        tap(element(app, "tab.letters"))
        let earlier = firstLetter(app)
        wait(earlier)
        XCTAssertFalse(earlier.label.contains("Written at"))
        tap(element(app, "tab.write"))
        let birthdayEntry = element(app, "write.child")
        assertTouchTarget(birthdayEntry)
        tap(birthdayEntry)
        tap(element(app, "child.birthday"))
        let date = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "November 21", "21 November")).firstMatch
        tap(date)
        tap(element(app, "child.save"), in: app)
        wait(element(app, "letter.age"))
        tap(element(app, "tab.letters"))
        wait(element(app, "folder.age"))
        tap(firstLetter(app), in: app)
        wait(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Written at 2y")).firstMatch)
    }

    func testReminderFromHomeHasThreeTapPresetAndExplainsPastEighteen() {
        let app = launch("-seed")
        let reminder = element(app, "write.reminder")
        assertTouchTarget(reminder)
        tap(reminder)
        assertTouchTarget(element(app, "reminder.eighteen"))
        tap(element(app, "reminder.eighteen"))
        tap(element(app, "reminder.save"), in: app)
        wait(element(app, "write.reminder"))

        app.terminate()
        let adult = launch("-seed", "-adult")
        tap(element(adult, "write.reminder"))
        let preset = element(adult, "reminder.eighteen")
        wait(preset)
        XCTAssertFalse(preset.isEnabled)
        wait(element(adult, "reminder.eighteen.reason"))
    }

    func testLatestLetterSharesInOneTapAndEditsInThree() {
        let app = launch("-seed")
        tap(element(app, "write.recent.share"), in: app)
        assertTouchTarget(element(app, "write.recent.share"))
        wait(element(app, "share.requested"))
        tap(element(app, "write.recent.edit"), in: app)
        let editor = element(app, "edit.body")
        tap(editor)
        editor.typeText(" A memory we kept.")
        tap(element(app, "edit.save"), in: app)
        wait(element(app, "write.recent.edit"))
    }

    func testIncomingPreviewCanChangeChildAndAccept() {
        let app = launch("-seed")
        tap(element(app, "tab.receive"))
        tap(element(app, "import.paste"))
        wait(element(app, "incoming.body"))
        tap(element(app, "child.1"), in: app)
        XCTAssertTrue(element(app, "incoming.add").label.contains("Theo"))
        tap(element(app, "incoming.add"), in: app)
        wait(element(app, "notice.status"))
        tap(firstLetter(app))
        XCTAssertTrue(element(app, "read.body").label.contains("Grandma"))
    }

    func testNamedCodePreselectsRecipientAndSavesInThreeTaps() {
        let app = launch("-seed", "-active-theo")
        XCTAssertTrue(element(app, "child.1").isSelected)
        tap(element(app, "tab.receive"))
        tap(element(app, "import.paste"))
        let summary = element(app, "incoming.body")
        wait(summary)
        XCTAssertFalse(summary.label.contains("Love, Grandma"))
        let accept = element(app, "incoming.add")
        XCTAssertTrue(accept.label.contains("Mia"))
        assertTouchTarget(accept)
        tap(accept, in: app)
        wait(element(app, "notice.status"))
    }

    func testAttachmentUsesSamePreviewAndKeepsImage() {
        let app = launch("-seed", "-fixture-file")
        tap(element(app, "tab.receive"))
        tap(element(app, "import.file"))
        wait(element(app, "incoming.body"))
        tap(element(app, "incoming.expand"), in: app)
        let full = element(app, "incoming.body.full")
        wait(full)
        XCTAssertTrue(full.label.contains("Love, Grandma"))
        wait(element(app, "incoming.attachment"))
        tap(element(app, "incoming.add"), in: app)
        wait(element(app, "notice.status"))
    }

    func testRestorePreviewMergesWithoutDuplicatingLetters() {
        let app = launch("-seed", "-expired", "-fixture-restore")
        tap(element(app, "write.settings"))
        tap(element(app, "settings.restore"), in: app)
        tap(element(app, "settings.merge"), in: app)
        wait(element(app, "notice.status"))
        XCTAssertTrue(element(app, "notice.status").label.contains("Backup merged"))
        tap(element(app, "nav.back"))
        tap(element(app, "tab.letters"))
        XCTAssertTrue(element(app, "Letters: 10").exists)
    }

    func testExpiredBookShowsSampleBeforeUpgrade() {
        let app = launch("-seed", "-expired")
        tap(element(app, "tab.letters"))
        tap(element(app, "folder.book"))
        wait(element(app, "Sample book"))
        wait(element(app, "book.preview.image"))
        tap(element(app, "book.pdf"), in: app)
        wait(element(app, "paywall.restore"))
    }

    func testDeletedLetterCanBeUndone() {
        let app = launch()
        write("A walk after the rain.", in: app)
        wait(element(app, "notice.status"))
        tap(element(app, "tab.letters"))
        tap(firstLetter(app))
        tap(element(app, "read.delete"), in: app)
        tap(element(app, "letter.undo"))
        tap(firstLetter(app))
        wait(element(app, "read.body"))
        XCTAssertTrue(element(app, "read.body").label.contains("after the rain"))
    }

    func testFamilyCanSendForFreeAfterTrialAndBackupRemainsFree() {
        let app = launch("-seed", "-expired", "-active-theo")
        tap(element(app, "write.family"), in: app)
        let body = element(app, "family.body")
        wait(app.keyboards.firstMatch)
        body.typeText("For many days to come.")
        tap(element(app, "family.share"), in: app)
        wait(element(app, "share.requested"))
        tap(element(app, "nav.back"))
        tap(element(app, "tab.letters"))
        tap(firstLetter(app))
        wait(element(app, "read.body"))
        tap(element(app, "read.edit"), in: app)
        wait(element(app, "edit.body"))
        tap(element(app, "nav.back"))
        tap(element(app, "nav.back"))
        tap(element(app, "child.1"))
        tap(element(app, "tab.write"))
        wait(element(app, "letter.body"))
        XCTAssertTrue(element(app, "child.0").isSelected)
        tap(element(app, "write.settings"))
        tap(element(app, "settings.backup"), in: app)
        wait(element(app, "share.requested"))
    }

    func testFamilyLetterWithPhotoAndSignatureSharesInThreeTapsFromHome() {
        let app = launch("-seed", "-family-photo")
        tap(element(app, "write.family"), in: app)
        wait(app.keyboards.firstMatch)
        element(app, "family.body").typeText("Here is a moment I saved for you.")
        tap(element(app, "family.photo"), in: app)
        wait(element(app, "family.attachment"))
        let sender = element(app, "family.sender")
        sender.typeText("Grandma")
        XCTAssertEqual(sender.value as? String, "Grandma")
        tap(element(app, "family.share"))
        wait(element(app, "share.requested"))
    }

    func testExpiredBootStartsOnFreeChildAndWritesInTwoTaps() {
        let app = launch("-seed", "-expired", "-active-theo")
        XCTAssertTrue(element(app, "child.0").isSelected)
        write("Still here for Mia.", in: app)
        wait(element(app, "notice.status"))
    }

    func testPaidFixtureAndRestoreAction() {
        let app = launch("-seed", "-expired", "-purchased")
        tap(element(app, "child.1"))
        wait(app.keyboards.firstMatch)
        element(app, "letter.body").typeText("A letter for Theo after trial.")
        tap(element(app, "write.save"))
        wait(element(app, "notice.status"))
        tap(element(app, "write.settings"))
        tap(element(app, "settings.purchaseRestore"), in: app)
        wait(element(app, "notice.status"))
        XCTAssertTrue(element(app, "notice.status").label.contains("Lifetime Pro"))
    }

    func testMilestoneShareAndRatingAfterThirdDay() {
        let app = launch("-seed", "-nine", "-review")
        write("A tenth little moment.", in: app)
        wait(element(app, "review.requested"))
        tap(element(app, "milestone.tenth"), in: app)
        let toggle = element(app, "card.nickname")
        wait(toggle)
        XCTAssertEqual(toggle.value as? String, "0")
        tap(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "1")
        tap(element(app, "card.share"), in: app)
        wait(element(app, "share.requested"))
    }

    func testStoreEnglish() { store(language: "en", locale: "en_US") }
    func testStoreSimplified() { store(language: "zh-Hans", locale: "zh_CN") }
    func testStoreTraditional() { store(language: "zh-Hant", locale: "zh_TW") }

    func testPaywallScreenshot() {
        let app = launch("-seed", "-paywall", language: "zh-Hans", locale: "zh_CN")
        wait(element(app, "paywall.buy"))
        shot("paid-01-paywall")
    }

    private func store(language: String, locale: String) {
        let app = launch("-seed", "-screenshots", language: language, locale: locale)
        wait(element(app, "letter.photo"))
        shot("store-\(language)-01-write")
        tap(element(app, "tab.letters"))
        wait(element(app, "folder.age"))
        shot("store-\(language)-02-letters")
        tap(firstLetter(app), in: app)
        wait(element(app, "read.body"))
        wait(element(app, "letter.photo"))
        shot("store-\(language)-03-read")
        tap(element(app, "nav.back"))
        tap(element(app, "folder.book"))
        wait(element(app, "book.page"))
        wait(element(app, "book.preview.image"))
        shot("store-\(language)-04-book")
        tap(element(app, "nav.back"))
        tap(element(app, "tab.receive"))
        tap(element(app, "import.paste"))
        wait(element(app, "incoming.body"))
        shot("store-\(language)-05-import")
        tap(element(app, "nav.back"))
        tap(element(app, "tab.write"))
        tap(element(app, "write.reminder"))
        for key in ["reminder.birthday", "reminder.eighteen", "reminder.graduation", "reminder.selectedDay"] {
            wait(element(app, key))
        }
        shot("store-\(language)-06-reminder")
    }

    @discardableResult
    private func launch(_ flags: String..., language: String = "en", locale: String = "en_US",
                        id: String = UUID().uuidString, reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-AppleLanguages", "(\(language))", "-AppleLocale", locale] + flags
        if reset { app.launchArguments.append("-reset") }
        app.launchEnvironment["GL_TEST_ID"] = id
        app.launch()
        if !flags.contains("-paywall") { wait(element(app, "tab.write")) }
        return app
    }

    private func firstLetter(_ app: XCUIApplication) -> XCUIElement {
        element(app, "letter.row")
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func assertTouchTarget(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        wait(element, file: file, line: line)
        XCTAssertTrue(element.isHittable, "\(element)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.width, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, file: file, line: line)
    }

    private func write(_ text: String, in app: XCUIApplication) {
        let editor = element(app, "letter.body")
        tap(editor)
        editor.typeText(text)
        tap(element(app, "write.save"))
    }

    private func wait(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 12), "\(element)", file: file, line: line)
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication? = nil,
                     file: StaticString = #filePath, line: UInt = #line) {
        if let app {
            for _ in 0..<5 where !element.waitForExistence(timeout: 3) { app.swipeUp() }
            wait(element, file: file, line: line)
            for _ in 0..<4 where !element.isHittable { app.swipeUp() }
        } else {
            wait(element, file: file, line: line)
        }
        XCTAssertTrue(element.isHittable, "\(element)", file: file, line: line)
        element.tap()
    }

    private func shot(_ title: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = title
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
