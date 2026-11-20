import XCTest
@testable import GuestLink

final class ActivityFuzzTests: XCTestCase {
    /// Regression (fuzzer): an activity report of 1e300 % processor use reached `Int(_:)` in the idle check.
    func testActivityReportsArriveClamped() {
        let a = GuestActivity(idleSeconds: Int.min, cpuPercent: 1e300, keepAwake: Array(repeating: String(repeating: "x", count: 1000), count: 100)).sanitized()
        XCTAssertEqual(a.idleSeconds, 0)
        XCTAssertEqual(a.cpuPercent, 100)
        XCTAssertEqual(a.keepAwake.count, 16)
        XCTAssertEqual(a.keepAwake[0].count, 200)
        let ordinary = GuestActivity(idleSeconds: 12, cpuPercent: 3.5, keepAwake: ["video"])
        XCTAssertEqual(ordinary.sanitized(), ordinary)
    }
}
