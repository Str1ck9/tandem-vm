import XCTest
@testable import VMCore

final class GuestDisplayScaleTests: XCTestCase {
    func testRetinaSizedScreenInAHalfSizeWindowGetsTwoHundredPercent() {
        XCTAssertEqual(GuestDisplayScale.recommendedPercent(guestWidth: 3024, viewWidthPoints: 1512), 200)
    }

    func testScreenAsWideAsTheWindowKeepsTheGuestsOwnScale() {
        XCTAssertEqual(GuestDisplayScale.recommendedPercent(guestWidth: 1512, viewWidthPoints: 1512), 100)
        // A little larger than the window is still left alone: below the threshold.
        XCTAssertEqual(GuestDisplayScale.recommendedPercent(guestWidth: 1700, viewWidthPoints: 1512), 100)
    }

    func testRatiosRoundToTheNearestStepWindowsOffers() {
        // The 3D display driver tops out at 1920 wide: 1920 / 1512 = 1.27 -> 125%.
        XCTAssertEqual(GuestDisplayScale.recommendedPercent(guestWidth: 1920, viewWidthPoints: 1512), 125)
        XCTAssertEqual(GuestDisplayScale.recommendedPercent(guestWidth: 2560, viewWidthPoints: 1440), 175)
        XCTAssertEqual(GuestDisplayScale.recommendedPercent(guestWidth: 3840, viewWidthPoints: 1280), 300)
    }

    func testEveryResultIsAScaleWindowsOffers() {
        for guest in stride(from: 800, through: 5120, by: 37) {
            for view in stride(from: 600, through: 3000, by: 113) {
                XCTAssertTrue(GuestDisplayScale.steps.contains(GuestDisplayScale.recommendedPercent(guestWidth: guest, viewWidthPoints: Double(view))))
            }
        }
    }

    func testNothingChangesWithoutAWindowSizeOrWhenSwitchedOff() {
        XCTAssertNil(GuestDisplayScale.target(guestWidth: 3024, viewWidthPoints: nil, enabled: true))
        XCTAssertNil(GuestDisplayScale.target(guestWidth: 3024, viewWidthPoints: 1512, enabled: false))
        XCTAssertNil(GuestDisplayScale.target(guestWidth: 0, viewWidthPoints: 1512, enabled: true))
        XCTAssertEqual(GuestDisplayScale.target(guestWidth: 3024, viewWidthPoints: 1512, enabled: true), 200)
    }

    func testDegenerateInputsFallBackToOneHundred() {
        XCTAssertEqual(GuestDisplayScale.recommendedPercent(guestWidth: 0, viewWidthPoints: 1000), 100)
        XCTAssertEqual(GuestDisplayScale.recommendedPercent(guestWidth: 1000, viewWidthPoints: 0), 100)
        XCTAssertEqual(GuestDisplayScale.recommendedPercent(guestWidth: 1000, viewWidthPoints: -5), 100)
    }

    func testTheSettingsDefaultAndSurviveACodableRoundTrip() throws {
        var display = DisplayConfig()
        XCTAssertTrue(display.matchWindowsScale, "matching the scale is on unless switched off")
        XCTAssertFalse(display.useRetinaResolution, "Retina resolution is opt-in")
        display.matchesWindowsScale = false
        display.retinaResolution = true
        let decoded = try JSONDecoder().decode(DisplayConfig.self, from: JSONEncoder().encode(display))
        XCTAssertFalse(decoded.matchWindowsScale)
        XCTAssertTrue(decoded.useRetinaResolution)
        // An older config without the keys decodes to the defaults.
        let old = try JSONDecoder().decode(DisplayConfig.self, from: Data(#"{"width":1440,"height":900,"dynamicResize":true}"#.utf8))
        XCTAssertTrue(old.matchWindowsScale)
        XCTAssertFalse(old.useRetinaResolution)
    }

    func testGuestPixelsAreEvenAndWithinWhatTheDisplayDeviceAccepts() {
        XCTAssertTrue(GuestDisplayScale.guestPixels(forPoints: 1512, 870, factor: 1) == (1512, 870))
        XCTAssertTrue(GuestDisplayScale.guestPixels(forPoints: 1511.5, 869.5, factor: 1) == (1510, 868))
        // Retina resolution: twice the points.
        XCTAssertTrue(GuestDisplayScale.guestPixels(forPoints: 1512, 870, factor: 2) == (3024, 1740))
        // Limits.
        XCTAssertTrue(GuestDisplayScale.guestPixels(forPoints: 300, 200, factor: 1) == (800, 600))
        XCTAssertTrue(GuestDisplayScale.guestPixels(forPoints: 3000, 2000, factor: 2) == (5120, 2880))
    }
}
