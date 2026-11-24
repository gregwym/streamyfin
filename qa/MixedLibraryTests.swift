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
        let server = element(app, "http(s)://your-server.com")
        #else
        let server = app.textFields["login-server-url"]
        #endif
        try require(server.waitForExistence(timeout: 25), app.debugDescription)
        try fill(server, in: app, "http://127.0.0.1:18096")
        try press(app, "Connect")
        let allow = app.alerts.buttons["Allow"]
        if allow.exists { try activate(allow, in: app) }

        #if os(tvOS)
        let username = element(app, "Username")
        #else
        let username = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Username")).firstMatch
        #endif
        let connectionError = app.alerts["Connection failed"].buttons["OK"]
        if !username.waitForExistence(timeout: 15), connectionError.exists {
            try activate(connectionError, in: app)
            try press(app, "Connect")
        }
        try require(username.waitForExistence(timeout: 25), app.debugDescription)
        try fill(username, in: app, "QA")
        #if os(tvOS)
        let password = element(app, "Password")
        #else
        let password = app.secureTextFields.firstMatch
        #endif
        try require(password.waitForExistence(timeout: 10), app.debugDescription)
        try fill(password, in: app, "StreamyfinFixture2536", secure: true)
        try press(app, "Log in")

        #if os(iOS)
        let done = element(app, "Done")
        if done.waitForExistence(timeout: 10) { try activate(done, in: app) }
        #endif

        try openMixedLibrary(app)
        try require(element(app, "Fixture Movie", containing: true).waitForExistence(timeout: 25), app.debugDescription)
        try require(element(app, "Fixture Series", containing: true).exists, app.debugDescription)
        let fixtureEpisode = NSPredicate(
            format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
            "Fixture Episode", "S1:E1", "S01E01"
        )
        let episode = app.descendants(matching: .any).matching(fixtureEpisode).firstMatch

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

    @MainActor
    private func openMixedLibrary(_ app: XCUIApplication) throws {
        try require(app.tabBars.buttons["Library"].firstMatch.waitForExistence(timeout: 25),
                    app.debugDescription)
        #if os(tvOS)
        try press(app, "Library")
        let card = app.otherElements.matching(
            NSPredicate(format: "label CONTAINS[c] %@", ", Mixed Fixture, ")
        ).firstMatch
        try require(card.waitForExistence(timeout: 25), app.debugDescription)
        XCUIRemote.shared.press(.down)
        try activate(card, in: app)
        if element(app, "Fixture Movie", containing: true).waitForExistence(timeout: 7) {
            return
        }
        print("Apple TV library navigation fell back to the app's deep link.")
        #endif
        // Open the real library route directly when the simulator's native
        // tab bar does not dispatch the navigation.
        guard let libraryID = ProcessInfo.processInfo.environment["STREAMYFIN_QA_LIBRARY_ID"],
              let libraryURL = URL(string: "streamyfin:///\(libraryID)") else {
            throw failure("Missing the Jellyfin fixture library URL.")
        }
        app.open(libraryURL)
        #if os(iOS)
        try require(app.navigationBars["Mixed Fixture"].waitForExistence(timeout: 25), app.debugDescription)
        #endif
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
    private func fill(_ field: XCUIElement, in app: XCUIApplication, _ text: String, secure: Bool = false) throws {
        try activate(field, in: app)
        #if os(tvOS)
        // The focusable app control opens a separate keyboard editor.
        let fields = secure ? app.secureTextFields : app.textFields
        let editor = fields.firstMatch
        if editor.waitForExistence(timeout: 5) {
            editor.typeText(text)
        } else {
            app.typeText(text)
        }
        let done = element(app, "Done")
        if done.exists {
            try activate(done, in: app)
        } else {
            XCUIRemote.shared.press(.menu)
        }
        #else
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        field.typeText(text)
        let entered = field.value as? String ?? ""
        let matched = secure ? entered.count == text.count : entered == text
        guard !matched else { return }

        let clear = field.buttons["Clear text"]
        if clear.exists {
            clear.tap()
        } else if !entered.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: entered.count))
        }
        for character in text {
            field.typeText(String(character))
        }
        let corrected = field.value as? String ?? ""
        try require(secure ? corrected.count == text.count : corrected == text,
                    "Simulator keyboard did not enter the complete text.")
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
        if control.isHittable {
            control.tap()
        } else {
            try require(!control.frame.isEmpty && app.frame.intersects(control.frame),
                        "Could not tap \(control.label). " + app.debugDescription)
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
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
