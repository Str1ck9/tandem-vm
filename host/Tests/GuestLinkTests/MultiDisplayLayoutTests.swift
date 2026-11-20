import CoreGraphics
import XCTest
@testable import GuestLink

final class MultiDisplayLayoutTests: XCTestCase {
    typealias Display = GuestWindowLayout.Display

    /// A MacBook (1512 x 945 usable at (0,37)) alone, at Retina resolution.
    func testOneRetinaDisplay() throws {
        let plan = try XCTUnwrap(GuestWindowLayout.plan(displays: [Display(visibleFrame: CGRect(x: 0, y: 37, width: 1512, height: 945), scale: 2, isMain: true)], retina: true))
        XCTAssertEqual(plan.area, CGRect(x: 0, y: 37, width: 1512, height: 945))
        XCTAssertEqual(plan.scale, 2)
        XCTAssertEqual(plan.pixels, CGSize(width: 3024, height: 1890))
        XCTAssertEqual(plan.mainWorkArea, CGRect(x: 0, y: 0, width: 3024, height: 1890))
    }

    /// An external display to the left of and higher than the MacBook: negative x, a taller top.
    func testExternalDisplayLeftAndAboveMapsBothWays() throws {
        let laptop = Display(visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 945), scale: 2, isMain: true)
        let external = Display(visibleFrame: CGRect(x: -1920, y: 200, width: 1920, height: 1055), scale: 1)
        let plan = try XCTUnwrap(GuestWindowLayout.plan(displays: [laptop, external], retina: true))
        XCTAssertEqual(plan.area, CGRect(x: -1920, y: 0, width: 3432, height: 1255))
        // 2x would be 6864 x 2510, wider than the device takes, so 1 pixel per point.
        XCTAssertEqual(plan.scale, 1)
        XCTAssertEqual(plan.pixels, CGSize(width: 3432, height: 1254))
        XCTAssertEqual(plan.mainWorkArea.minX, 1920)
        XCTAssertEqual(plan.mainWorkArea.minY, 310)

        let layout = GuestWindowLayout(desktop: plan.pixels, area: plan.area)
        let onExternal = layout.macFrame(forGuestRect: CGRect(x: 100, y: 100, width: 800, height: 600))
        XCTAssertTrue(external.visibleFrame.contains(onExternal), "\(onExternal)")
        let onLaptop = layout.macFrame(forGuestRect: CGRect(x: plan.mainWorkArea.minX + 50, y: plan.mainWorkArea.minY + 50, width: 400, height: 300))
        XCTAssertTrue(laptop.visibleFrame.contains(onLaptop), "\(onLaptop)")
        let p = layout.guestPoint(forMacPoint: CGPoint(x: onExternal.minX + 0.5, y: onExternal.maxY - 0.5))
        XCTAssertEqual(p.x, 100); XCTAssertEqual(p.y, 100)
    }

    /// Two small Retina displays side by side still fit at 2x.
    func testTwoSmallRetinaDisplaysStayAt2x() throws {
        let a = Display(visibleFrame: CGRect(x: 0, y: 0, width: 1280, height: 800), scale: 2, isMain: true)
        let b = Display(visibleFrame: CGRect(x: 1280, y: 0, width: 1280, height: 800), scale: 2)
        let plan = try XCTUnwrap(GuestWindowLayout.plan(displays: [a, b], retina: true))
        XCTAssertEqual(plan.scale, 2)
        XCTAssertEqual(plan.pixels, CGSize(width: 5120, height: 1600))
        XCTAssertEqual(plan.mainWorkArea, CGRect(x: 0, y: 0, width: 2560, height: 1600))
    }

    /// A display below the main one: negative y.
    func testDisplayBelowTheMainOne() throws {
        let main = Display(visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875), scale: 1, isMain: true)
        let below = Display(visibleFrame: CGRect(x: 0, y: -900, width: 1600, height: 900), scale: 1)
        let plan = try XCTUnwrap(GuestWindowLayout.plan(displays: [main, below], retina: false))
        XCTAssertEqual(plan.area, CGRect(x: 0, y: -900, width: 1600, height: 1775))
        XCTAssertEqual(plan.mainWorkArea, CGRect(x: 0, y: 0, width: 1440, height: 875))
        let layout = GuestWindowLayout(desktop: plan.pixels, area: plan.area)
        let low = layout.macFrame(forGuestRect: CGRect(x: 10, y: 1000, width: 200, height: 100))
        XCTAssertTrue(below.visibleFrame.contains(low), "\(low)")
    }

    /// Without Retina resolution, always 1 pixel per point; an arrangement too big even for that shrinks.
    func testNoRetinaAndOversizedArrangements() throws {
        let a = Display(visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 945), scale: 2, isMain: true)
        XCTAssertEqual(GuestWindowLayout.plan(displays: [a], retina: false)?.scale, 1)
        let wide = Display(visibleFrame: CGRect(x: 1512, y: 0, width: 5120, height: 1440), scale: 1)
        let plan = try XCTUnwrap(GuestWindowLayout.plan(displays: [a, wide], retina: true))
        XCTAssertLessThan(plan.scale, 1)
        XCTAssertLessThanOrEqual(plan.pixels.width, 5120)
        XCTAssertLessThanOrEqual(plan.pixels.height, 2880)
        XCTAssertNil(GuestWindowLayout.plan(displays: [], retina: true))
    }

    /// Resizing by the bottom-right corner grows the frame with the pointer; by the left edge it moves the
    /// left side and keeps the right one; a plain move keeps the size.
    func testResizePrediction() {
        let start = GuestWindowMove(id: 1, x: 100, y: 100, width: 400, height: 300, pointerX: 500, pointerY: 400, edge: .bottomRight)
        XCTAssertEqual(GuestWindowLayout.draggedRect(start, pointer: (560, 450)), CGRect(x: 100, y: 100, width: 460, height: 350))
        var left = start; left.edge = .left; left.pointerX = 100; left.pointerY = 250
        XCTAssertEqual(GuestWindowLayout.draggedRect(left, pointer: (60, 260)), CGRect(x: 60, y: 100, width: 440, height: 300))
        var top = start; top.edge = .top; top.pointerX = 300; top.pointerY = 100
        XCTAssertEqual(GuestWindowLayout.draggedRect(top, pointer: (300, 150)), CGRect(x: 100, y: 150, width: 400, height: 250))
        // Shrinking never goes below a small minimum.
        XCTAssertEqual(GuestWindowLayout.draggedRect(start, pointer: (0, 0)).size, CGSize(width: GuestWindowLayout.minimumPredictedSize.width, height: GuestWindowLayout.minimumPredictedSize.height))
        var move = start; move.edge = nil; move.pointerX = 300; move.pointerY = 110
        XCTAssertEqual(GuestWindowLayout.draggedRect(move, pointer: (320, 140)), CGRect(x: 120, y: 130, width: 400, height: 300))
    }

    func testMoveReportWithEdgeDecodes() throws {
        let json = #"{"desktop":[100,50],"windows":[],"moving":{"id":7,"x":10,"y":20,"width":300,"height":200,"pointerX":150,"pointerY":30,"edge":"bottomRight"}}"#
        let list = try JSONDecoder().decode(GuestWindowList.self, from: Data(json.utf8))
        XCTAssertEqual(list.moving?.edge, .bottomRight)
        let old = #"{"desktop":[100,50],"windows":[],"moving":{"id":7,"x":10,"y":20,"width":300,"height":200,"pointerX":150,"pointerY":30}}"#
        XCTAssertNil(try JSONDecoder().decode(GuestWindowList.self, from: Data(old.utf8)).moving?.edge)
    }
}
