import XCTest
@testable import MoshPit

@MainActor
final class WelcomeTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "welcometests.\(UUID().uuidString)")!
    }

    func testPresentWelcomeShowsAndClosesOtherOverlays() {
        let app = AppModel()
        app.showCheatSheet = true
        app.presentWelcome()
        XCTAssertTrue(app.showWelcome)
        XCTAssertFalse(app.showCheatSheet, "mutual exclusivity")
        XCTAssertNil(app.activePanel)
    }

    func testPresentWelcomeWaitsForDrawerToCloseFirst() {
        let app = AppModel()
        app.openDrawer = .left
        app.presentWelcome()
        XCTAssertNil(app.openDrawer, "drawer animates away first")
        XCTAssertFalse(app.showWelcome, "welcome is deferred, not stacked on the drawer")
    }

    func testDismissPersistsSeenAndHandsOffToCoachMarks() async {
        let defaults = freshDefaults()
        let app = AppModel()
        app.showWelcome = true
        app.welcomeDismissed(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: AppModel.hasSeenWelcomeKey))
        XCTAssertFalse(app.showWelcome)
        let deadline = Date(timeIntervalSinceNow: 3)
        while app.coachIndex == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(app.coachIndex, 0, "coach marks start after the welcome")
    }

    func testDismissDoesNotRestartCoachMarksIfAlreadySeen() async {
        let defaults = freshDefaults()
        defaults.set(true, forKey: CoachScript.hasSeenKey)
        let app = AppModel()
        app.welcomeDismissed(defaults: defaults)
        try? await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertNil(app.coachIndex, "replaying the welcome must not restart the tour")
    }

    func testCopyIsHonestAboutPricingAndNeverHardcodesAPrice() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MoshPit/App/Welcome.swift")
        let text = try String(contentsOf: root, encoding: .utf8)
        XCTAssertTrue(text.contains("watermark"))
        XCTAssertTrue(text.contains("no subscription"))
        XCTAssertNil(text.range(of: #"\$\d"#, options: .regularExpression), "price must come from StoreKit, never hard-coded")
        XCTAssertFalse(text.contains("requestAccess"), "no permission prompts on the welcome")
    }
}
