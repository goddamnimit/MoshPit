import XCTest
@testable import MoshPit

final class AutomationTests: XCTestCase {
    func testRecordCapturesChangesWithTimestamps() {
        let store = ParameterStore()
        let engine = AutomationEngine(store: store)
        engine.startRecording()
        store.set(.mixAmount, 0.8, origin: .ui)
        store.set(.bloomRate, 3, origin: .midi)

        // Changes arrive via Combine on main; give the runloop a beat.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let session = engine.stopRecording(name: "test-take") else {
            return XCTFail("no session recorded")
        }
        defer { engine.delete(session) }

        XCTAssertEqual(session.name, "test-take")
        XCTAssertEqual(session.events.count, 2)
        XCTAssertEqual(session.events[0].id, .mixAmount)
        XCTAssertEqual(session.events[0].value, 0.8, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(session.events[0].t, session.events[1].t)
        // Initial state snapshot restores the pre-take world on replay.
        XCTAssertEqual(session.initialState[ParameterID.mixAmount.rawValue],
                       ParameterID.mixAmount.defaultValue)
    }

    func testReplayAppliesEventsAndRestoresInitialState() {
        let store = ParameterStore()
        let engine = AutomationEngine(store: store)
        engine.loopPlayback = false
        let session = AutomationSession(
            name: "synthetic", createdAt: Date(), duration: 0.01,
            initialState: [ParameterID.mixAmount.rawValue: 0.15],
            events: [AutomationEvent(t: 0, id: .mixAmount, value: 0.9)])

        store.set(.mixAmount, 0.5, origin: .ui)
        engine.play(session)
        XCTAssertEqual(store.get(.mixAmount), 0.15, accuracy: 1e-6) // initial restored
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.tick()   // render loop drives playback
        XCTAssertEqual(store.get(.mixAmount), 0.9, accuracy: 1e-6)
        engine.tick()
        XCTAssertFalse(engine.isPlaying) // one-shot completed
    }

    func testAutomationEventsDoNotRecordThemselves() {
        let store = ParameterStore()
        let engine = AutomationEngine(store: store)
        engine.startRecording()
        store.set(.heal, 0.01, origin: .automation)   // replay-origin: ignored
        store.set(.heal, 0.02, origin: .ui)           // user move: recorded
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let session = engine.stopRecording() else { return XCTFail() }
        defer { engine.delete(session) }
        XCTAssertEqual(session.events.count, 1)
        XCTAssertEqual(session.events[0].value, 0.02, accuracy: 1e-6)
    }

    func testSessionCodableRoundTrip() throws {
        let session = AutomationSession(
            name: "rt", createdAt: Date(), duration: 2,
            initialState: ["mixAmount": 0.5],
            events: [AutomationEvent(t: 1, id: .driftX, value: -0.5)])
        let data = try JSONEncoder().encode(session)
        let back = try JSONDecoder().decode(AutomationSession.self, from: data)
        XCTAssertEqual(back, session)
    }
}
