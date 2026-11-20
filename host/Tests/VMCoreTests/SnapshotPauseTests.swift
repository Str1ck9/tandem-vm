import XCTest
@testable import VMCore

/// Review finding R17: a snapshot of a VM the user paused must leave it paused. Both engines record a
/// `SnapshotPause` in `prepareSnapshot` and resume in `finishSnapshot` only when it says so.
final class SnapshotPauseTests: XCTestCase {
    func testOnlyARunningVMRunsOnAfterASnapshot() {
        XCTAssertTrue(SnapshotPause(stateBefore: .running).resumeAfterwards)
        XCTAssertEqual(SnapshotPause(stateBefore: .running).stateAfterwards, .running)
        XCTAssertFalse(SnapshotPause(stateBefore: .paused).resumeAfterwards)
        XCTAssertEqual(SnapshotPause(stateBefore: .paused).stateAfterwards, .paused)
        for state in VMState.allCases where state != .running {
            XCTAssertFalse(SnapshotPause(stateBefore: state).resumeAfterwards, "\(state)")
        }
    }

    func testBothEnginesUseIt() throws {
        // The engines need a real VM to run; this guards against either one going back to resuming unconditionally.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        for file in ["EngineQEMU/QEMUEngine.swift", "EngineVZ/VZEngine.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            let finish = try XCTUnwrap(text.range(of: "public func finishSnapshot()"), file)
            let body = String(text[finish.upperBound...].prefix(600))
            XCTAssertTrue(body.contains("resumeAfterwards"), "\(file): finishSnapshot must check SnapshotPause")
            XCTAssertTrue(text.contains("SnapshotPause(stateBefore: lifecycle.state)"), file)
        }
    }
}
