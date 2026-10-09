import XCTest
@testable import MoshPit

/// Labels + hints coverage: every registered parameter, mode, panel and hint
/// group has a friendly title and a plain-language hint, and display text
/// never leaks identifiers or stale claims.
final class LabelsTests: XCTestCase {

    func testEveryParameterHasTitleAndHint() {
        for id in ParameterID.allCases {
            let entry = Labels.paramTable[id]
            XCTAssertNotNil(entry, "\(id.rawValue) has no label entry")
            XCTAssertFalse(entry?.title.isEmpty ?? true, "\(id.rawValue) title")
            XCTAssertGreaterThan(entry?.hint.count ?? 0, 15, "\(id.rawValue) hint too short")
        }
        XCTAssertEqual(Labels.paramTable.count, ParameterID.allCases.count,
                       "no stray entries for removed parameters")
    }

    func testEveryModePanelAndGroupHasHint() {
        for m in MoshMode.allCases {
            XCTAssertGreaterThan(Labels.mode(m).hint.count, 15, "mode \(m)")
        }
        for p in AppModel.Panel.allCases {
            XCTAssertGreaterThan(Labels.panel(p).hint.count, 15, "panel \(p)")
        }
        for g in Labels.Group.allCases {
            XCTAssertGreaterThan(Labels.group(g).hint.count, 15, "group \(g)")
        }
        for s in ModSource.allCases { XCTAssertFalse(Labels.modSource(s).isEmpty) }
    }

    func testHintKeyEntriesAreNeverEmpty() {
        for id in ParameterID.allCases {
            XCTAssertFalse(HintKey.param(id).entry.hint.isEmpty,
                           "the ? button would silently vanish for \(id.rawValue)")
        }
    }

    func testModeTitlesAreUniqueAndOriginalNamesPreserved() {
        let titles = MoshMode.allCases.map { Labels.mode($0).title }
        XCTAssertEqual(Set(titles).count, titles.count)
        XCTAssertEqual(Labels.mode(.classicSmear).title, "Smear")
        XCTAssertEqual(Labels.mode(.classicSmear).original, "Classic Smear")
        // Identifiers are untouched by the renames.
        XCTAssertEqual(MoshMode.classicSmear.title, "Classic Smear")
        XCTAssertEqual(ModSource.meanLuma.rawValue, "Mean Luma")
        XCTAssertEqual(ParameterID.bloomThreshold.rawValue, "bloomThreshold")
    }

    func testDrawerRowTitlesFitCompactRows() {
        let drawerRows: [ParameterID] = [.motionGain, .heal, .bloomRate, .bloomThreshold,
                                         .bloomAngle, .bloomBias, .bloomDecay, .mixAmount,
                                         .feedbackZoom, .feedbackRotate, .feedbackHue, .blockSize]
        for id in drawerRows {
            XCTAssertLessThanOrEqual(Labels.param(id).title.count, 12, "\(id.rawValue)")
        }
    }

    func testHintsAvoidUnexplainedJargon() {
        let banned = ["motion vector", "RGBA", "LFO", "optical flow", "I-frame", "Metal", "shader"]
        var all: [LabelEntry] = ParameterID.allCases.map(Labels.param)
        all += MoshMode.allCases.map(Labels.mode)
        all += AppModel.Panel.allCases.map(Labels.panel)
        all += Labels.Group.allCases.map(Labels.group)
        for entry in all {
            for word in banned {
                XCTAssertFalse(entry.hint.contains(word), "'\(word)' in hint for \(entry.title)")
            }
            XCTAssertLessThanOrEqual(entry.hint.count, 260, "\(entry.title) hint too long")
        }
    }

    func testTutorialAndDemoCopyUsesCurrentNamesAndPricingModel() {
        var texts = CoachScript.stops.map(\.text)
        texts += DemoLibrary.all.map(\.blurb)
        let stale = ["Photos.", "save to Photos", "Both save", "Thresh", "T-Bloom", "Sources panel",
                     "Sources (camera", "LFO", "mod matrix", "Proc-Amp"]
        for t in texts {
            for word in stale {
                XCTAssertFalse(t.contains(word), "stale '\(word)' in: \(t)")
            }
        }
        // Coach copy references the friendly names, not the old ones.
        let joined = CoachScript.stops.map(\.text).joined(separator: " ")
        XCTAssertTrue(joined.contains(Labels.mode(.classicSmear).title))
        XCTAssertTrue(joined.contains("watermark"))
    }
}
