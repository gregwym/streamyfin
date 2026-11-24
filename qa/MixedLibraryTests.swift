import XCTest

final class MixedLibraryTests: XCTestCase {
    @MainActor
    func testMixedLibrary() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: QAConfiguration.bundle)
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        #if os(tvOS)
        try press(app, "Add server", timeout: 25)
        #endif
        let server = app.textFields.firstMatch
        try require(server.waitForExistence(timeout: 25), app.debugDescription)
        try fill(server, in: app, "http://127.0.0.1:18096")
        try press(app, "Connect")
        let allow = app.alerts.buttons["Allow"]
        if allow.exists { try activate(allow, in: app) }

        let username = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Username")).firstMatch
        try require(username.waitForExistence(timeout: 20), app.debugDescription)
        try fill(username, in: app, "QA")
        let password = app.secureTextFields.firstMatch
        try require(password.waitForExistence(timeout: 10), app.debugDescription)
        try fill(password, in: app, "StreamyfinFixture2536")
        try press(app, "Log in")

        #if os(iOS)
        let done = element(app, "Done")
        if done.waitForExistence(timeout: 10) { try activate(done, in: app) }
        #endif

        try press(app, "Library", timeout: 25)
        try press(app, "Mixed Fixture", containing: true, timeout: 25)
        try require(element(app, "Fixture Movie", containing: true).waitForExistence(timeout: 25), app.debugDescription)
        try require(element(app, "Fixture Series", containing: true).exists, app.debugDescription)
        let episode = element(app, "S01E01", containing: true)

        if QAConfiguration.baseline {
            try require(episode.exists, "Upstream baseline did not reproduce the extra episode row. " + app.debugDescription)
        } else {
            try require(!episode.exists, "The updated library still shows an episode in its grid.")
            try require(!element(app, "Season 1").exists, "The updated library still shows a season in its grid.")
        }
        attachScreen(QAConfiguration.variant + "-mixed-library")

        if !QAConfiguration.baseline {
            try press(app, "Fixture Series", containing: true)
            let season = element(app, "Season 1", containing: true)
            if !episode.waitForExistence(timeout: 9) {
                try require(season.waitForExistence(timeout: 12), app.debugDescription)
                try activate(season, in: app)
                try require(episode.waitForExistence(timeout: 12), app.debugDescription)
            }
            attachScreen(QAConfiguration.variant + "-series-episode")
        }
    }

    private func require(_ condition: Bool, _ diagnostic: @autoclosure () -> String) throws {
        if !condition { throw failure(diagnostic()) }
    }

    private func failure(_ diagnostic: String) -> NSError {
        NSError(domain: "MixedLibraryTests", code: 1, userInfo: [NSLocalizedDescriptionKey: diagnostic])
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ title: String, containing: Bool = false) -> XCUIElement {
        let predicate = containing
            ? NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@", title, title)
            : NSPredicate(format: "identifier ==[c] %@ OR label ==[c] %@ OR label ENDSWITH[c] %@",
                          title, title, ", " + title)
        let buttons = app.buttons.matching(predicate)
        if buttons.firstMatch.exists { return buttons.firstMatch }
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    @MainActor
    private func press(_ app: XCUIApplication, _ title: String, containing: Bool = false, timeout: Double = 12) throws {
        let control = element(app, title, containing: containing)
        try require(control.waitForExistence(timeout: timeout), "Missing \(title). " + app.debugDescription)
        try activate(control, in: app)
    }

    @MainActor
    private func fill(_ field: XCUIElement, in app: XCUIApplication, _ text: String) throws {
        try activate(field, in: app)
        #if os(tvOS)
        // Some tvOS inputs open the system keyboard in a different text field.
        let editor = app.textFields.matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        if editor.exists {
            editor.typeText(text)
        } else {
            field.typeText(text)
        }
        let done = element(app, "Done")
        if done.exists {
            try activate(done, in: app)
        } else if app.keyboards.firstMatch.exists {
            XCUIRemote.shared.press(.menu)
        }
        #else
        field.typeText(text + "\n")
        #endif
    }

    @MainActor
    private func activate(_ control: XCUIElement, in app: XCUIApplication) throws {
        #if os(tvOS)
        let remote = XCUIRemote.shared
        var previousFrame = CGRect.null
        for step in 0..<14 {
            let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
            if control.hasFocus || (focused.exists && focused.frame.contains(control.frame)) {
                remote.press(.select)
                return
            }
            let frame = focused.exists ? focused.frame : .null
            if frame.isNull {
                remote.press(.down)
            } else {
                let dx = control.frame.midX - frame.midX
                let dy = control.frame.midY - frame.midY
                let moved = frame != previousFrame
                let horizontal = moved ? abs(dx) > abs(dy) : (step % 2 == 0)
                remote.press(horizontal ? (dx < 0 ? .left : .right) : (dy < 0 ? .up : .down))
            }
            previousFrame = frame
        }
        throw failure("Could not focus \(control.label). " + app.debugDescription)
        #else
        control.tap()
        #endif
    }

    @MainActor
    private func attachScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
