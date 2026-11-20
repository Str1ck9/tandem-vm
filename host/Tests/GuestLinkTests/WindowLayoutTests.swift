import CoreGraphics
import XCTest
@testable import GuestLink

final class WindowLayoutTests: XCTestCase {
    private func window(_ id: UInt64, _ x: Int, _ y: Int, _ w: Int, _ h: Int, kind: GuestWindow.Kind = .app,
                        state: GuestWindow.State = .normal) -> GuestWindow {
        GuestWindow(id: id, x: x, y: y, width: w, height: h, pid: 1, kind: kind, state: state, active: false,
                    title: "t", class: "c", app: "a.exe")
    }

    /// A Mac screen area that starts above the Dock: 1440 x 800 points at (0, 70).
    private let layout = GuestWindowLayout(desktop: CGSize(width: 1440, height: 800), area: CGRect(x: 0, y: 70, width: 1440, height: 800))

    func testGuestTopLeftBecomesMacBottomLeftOrigin() {
        // 100 px from the guest's top edge is 100 pt below the top of the area.
        let frame = layout.macFrame(forGuestRect: CGRect(x: 10, y: 100, width: 300, height: 200))
        XCTAssertEqual(frame, CGRect(x: 10, y: 70 + 800 - 300, width: 300, height: 200))
    }

    func testPointerMapsBackToTheSameGuestPixel() {
        let frame = layout.macFrame(forGuestRect: CGRect(x: 10, y: 100, width: 300, height: 200))
        // The Mac frame's top-left corner is the guest rectangle's top-left pixel.
        let p = layout.guestPoint(forMacPoint: CGPoint(x: frame.minX + 0.5, y: frame.maxY - 0.5))
        XCTAssertEqual(p.x, 10); XCTAssertEqual(p.y, 100)
        // Outside the area clamps to the guest's screen.
        let q = layout.guestPoint(forMacPoint: CGPoint(x: -50, y: 5000))
        XCTAssertEqual(q.x, 0); XCTAssertEqual(q.y, 0)
        let r = layout.guestPoint(forMacPoint: CGPoint(x: 9000, y: 0))
        XCTAssertEqual(r.x, 1439); XCTAssertEqual(r.y, 799)
    }

    func testAGuestScreenOfAnotherSizeIsScaledOntoTheArea() {
        let half = GuestWindowLayout(desktop: CGSize(width: 720, height: 400), area: layout.area)
        XCTAssertEqual(half.macFrame(forGuestRect: CGRect(x: 0, y: 0, width: 720, height: 400)), layout.area)
        let p = half.guestPoint(forMacPoint: CGPoint(x: 720, y: 70 + 400))
        XCTAssertEqual(p.x, 360); XCTAssertEqual(p.y, 200)
    }

    func testWindowsPartlyOffScreenAreClippedAndOthersLeftOut() {
        let partly = window(1, -100, 700, 400, 300)
        XCTAssertEqual(layout.visibleRect(of: partly), CGRect(x: 0, y: 700, width: 300, height: 100))
        XCTAssertEqual(layout.unitRect(forGuestRect: CGRect(x: 0, y: 700, width: 300, height: 100)),
                       CGRect(x: 0, y: 0.875, width: 300.0 / 1440, height: 0.125))
        let list = [window(2, 0, 752, 1440, 48, kind: .taskbar), partly, window(3, 5000, 0, 10, 10),
                    window(4, 0, 0, 100, 100, state: .minimized), window(5, 20, 20, 50, 20, kind: .popup)]
        XCTAssertEqual(layout.shown(list).map(\.id), [1, 5], "front-most first; task bar, off-screen and minimised left out")
    }

    func testWindowReportDecodes() throws {
        let json = #"{"desktop":[1440,818],"windows":[{"id":4294967298,"x":-8,"y":0,"width":800,"height":600,"pid":42,"kind":"app","state":"maximized","active":true,"title":"a \"b\"","class":"Notepad","app":"notepad.exe"}]}"#
        let list = try JSONDecoder().decode(GuestWindowList.self, from: Data(json.utf8))
        XCTAssertEqual(list.desktop, [1440, 818])
        XCTAssertEqual(list.windows[0].id, 4294967298)
        XCTAssertEqual(list.windows[0].state, .maximized)
        XCTAssertEqual(list.windows[0].title, "a \"b\"")
    }

    func testRetinaDesktopMapsTwoGuestPixelsToOnePoint() {
        // A 1512 x 870 point area above a 79 pt Dock, guest at twice the pixels.
        let retina = GuestWindowLayout(desktop: CGSize(width: 3024, height: 1740), area: CGRect(x: 0, y: 79, width: 1512, height: 870))
        XCTAssertEqual(retina.macFrame(forGuestRect: CGRect(x: 100, y: 200, width: 800, height: 600)),
                       CGRect(x: 50, y: 79 + 870 - 400, width: 400, height: 300))
        let p = retina.guestPoint(forMacPoint: CGPoint(x: 50.25, y: 79 + 870 - 100.25))
        XCTAssertEqual(p.x, 100); XCTAssertEqual(p.y, 200)
        // The picture is cut from the same place whatever the scale.
        XCTAssertEqual(retina.unitRect(forGuestRect: CGRect(x: 0, y: 0, width: 1512, height: 870)), CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
    }

    func testDesktopIsLaidOverWholeScreenPixels() {
        let area = CGRect(x: 0, y: 79, width: 1512, height: 870)
        // Asked for 3024 x 1740, the driver took 1748 lines: 2 px a point, 874 points high, from the top.
        XCTAssertEqual(GuestWindowLayout.pixelExactArea(desktop: CGSize(width: 3024, height: 1748), screen: area),
                       CGRect(x: 0, y: 79 + 870 - 874, width: 1512, height: 874))
        XCTAssertEqual(GuestWindowLayout.pixelExactArea(desktop: CGSize(width: 3024, height: 1740), screen: area), area)
        XCTAssertEqual(GuestWindowLayout.pixelExactArea(desktop: CGSize(width: 1512, height: 866), screen: area),
                       CGRect(x: 0, y: 79 + 4, width: 1512, height: 866))
        // Far from a whole multiple: stretched over the area as before.
        XCTAssertEqual(GuestWindowLayout.pixelExactArea(desktop: CGSize(width: 1920, height: 1080), screen: area), area)
    }

    func testDraggedWindowFollowsThePointer() {
        let move = GuestWindowMove(id: 7, x: 100, y: 50, width: 900, height: 600, pointerX: 600, pointerY: 64)
        XCTAssertEqual(GuestWindowLayout.draggedRect(move, pointer: (600, 64)), CGRect(x: 100, y: 50, width: 900, height: 600))
        XCTAssertEqual(GuestWindowLayout.draggedRect(move, pointer: (850, 30)), CGRect(x: 350, y: 16, width: 900, height: 600))
        // Grabbed at (592, 60): Windows began the move 8 px later, but keeps the grabbed point under the pointer.
        XCTAssertEqual(GuestWindowLayout.draggedRect(move, pointer: (850, 30), pressedAt: (592, 60)), CGRect(x: 358, y: 20, width: 900, height: 600))
    }

    func testReportWithAWindowBeingDraggedDecodes() throws {
        let json = #"{"desktop":[100,50],"windows":[],"moving":{"id":7,"x":10,"y":20,"width":300,"height":200,"pointerX":150,"pointerY":30}}"#
        let list = try JSONDecoder().decode(GuestWindowList.self, from: Data(json.utf8))
        XCTAssertEqual(list.moving, GuestWindowMove(id: 7, x: 10, y: 20, width: 300, height: 200, pointerX: 150, pointerY: 30))
        let older = try JSONDecoder().decode(GuestWindowList.self, from: Data(#"{"desktop":[100,50],"windows":[]}"#.utf8))
        XCTAssertNil(older.moving, "reports from older guest tools have no drag")
    }
}
