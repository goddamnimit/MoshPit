import XCTest
@testable import MoshPit

final class TutorialTests: XCTestCase {
    /// The coach-mark script must cover all 12 stops in the specified order,
    /// and drawer-hosted stops must name the drawer that contains them.
    func testCoachSequenceCoversAllStopsInOrder() {
        let stops = CoachScript.stops
        XCTAssertEqual(stops.count, 12)
        let expectedAnchors: [CoachAnchor] = [
            .canvas, .leftHandle, .modeList, .panelTriggers, .rightHandle,
            .xyPad, .paramRows, .resetButton, .recordButton, .bloomButton,
            .hudPill, .finale,
        ]
        XCTAssertEqual(stops.map(\.anchor), expectedAnchors)

        // Drawer mapping: mode list + panel triggers live in the LEFT drawer;
        // XY pad + param rows live in the RIGHT drawer; everything else needs
        // no drawer open.
        for stop in stops {
            switch stop.anchor {
            case .modeList, .panelTriggers:
                XCTAssertEqual(stop.drawer, .left, "\(stop.anchor) is in the left drawer")
            case .xyPad, .paramRows:
                XCTAssertEqual(stop.drawer, .right, "\(stop.anchor) is in the right drawer")
            default:
                XCTAssertNil(stop.drawer, "\(stop.anchor) needs no drawer")
            }
        }
        // Every stop has real copy; no anchor repeats.
        XCTAssertTrue(stops.allSatisfy { $0.text.count > 20 })
        XCTAssertEqual(Set(stops.map(\.anchor)).count, stops.count)
    }

    func testDemoLibraryShape() {
        let demos = DemoLibrary.all
        // Expanded library: full feature coverage needs at least 28 demos.
        XCTAssertGreaterThanOrEqual(demos.count, 28)
        // IDs and titles are both unique (titles are the user-facing key).
        XCTAssertEqual(Set(demos.map(\.id)).count, demos.count)
        XCTAssertEqual(Set(demos.map(\.title)).count, demos.count)
    }

    func testEverySectionHasDemosAndEveryDemoHasASection() {
        for section in DemoLibrary.sections {
            XCTAssertFalse(DemoLibrary.demos(in: section).isEmpty,
                           "section \(section) has no demos")
        }
        // No demo points at a section the sheet doesn't render.
        let known = Set(DemoLibrary.sections)
        for demo in DemoLibrary.all {
            XCTAssertTrue(known.contains(demo.section),
                          "\(demo.id) has unknown section \(demo.section)")
        }
    }
}
