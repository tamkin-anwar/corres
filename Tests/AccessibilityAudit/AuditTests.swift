import XCTest

/// Apple's own accessibility audit (the one in Accessibility Inspector),
/// run on Corres's main screens with sample mail: labels, contrast, hit
/// areas, clipped text and Dynamic Type. Install a Debug build of Corres
/// on the simulator first; see README.md.
final class AuditTests: XCTestCase {
    private var app: XCUIApplication!
    private var report: [String] = []

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication(bundleIdentifier: "studio.anwarcreative.corres")
        app.launchArguments = ["-SampleMailOnly", "-CorresScreenshots", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Maya Chen"].waitForExistence(timeout: 60))
    }

    override func tearDown() {
        print("AUDIT \(name): \(report.count) issues")
        for line in report { print("AUDIT   " + line) }
    }

    private func audit(_ screen: String) throws {
        let shot = XCUIScreen.main.screenshot().pngRepresentation
        try? shot.write(to: URL(fileURLWithPath: "/tmp/claude-501/audit-\(screen).png"))
        try app.performAccessibilityAudit { issue in
            let element = issue.element.map { "\($0.elementType.rawValue) '\($0.label)'" } ?? "-"
            self.report.append("[\(screen)] \(issue.auditType.rawValue) \(issue.compactDescription) :: \(element)")
            return true
        }
    }

    func testMailList() throws {
        try audit("list")
    }

    func testConversation() throws {
        app.staticTexts["Maya Chen"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["The next chapter"].waitForExistence(timeout: 20))
        sleep(2)
        try audit("conversation")
    }

    func testCompose() throws {
        app.buttons["New message"].firstMatch.tap()
        sleep(2)
        try audit("compose")
    }

    func testSettings() throws {
        let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Account'")).firstMatch
        button.tap()
        sleep(2)
        try audit("settings")
        if app.buttons["Composing"].waitForExistence(timeout: 5) {
            app.buttons["Composing"].tap()
            sleep(2)
            try audit("settings-composing")
        }
    }

    func testMailboxes() throws {
        app.buttons["Mailboxes"].firstMatch.tap()
        sleep(2)
        try audit("mailboxes")
    }

    func testSearch() throws {
        let field = app.searchFields.firstMatch
        field.tap()
        field.typeText("delivery")
        app.keyboards.buttons["search"].firstMatch.tap()
        sleep(3)
        try audit("search")
    }
}
