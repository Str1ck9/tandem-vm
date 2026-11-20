import Foundation
import XCTest
@testable import GuestLink

final class DragOutTests: XCTestCase {
    func testFileNamesComeFromWindowsPaths() {
        XCTAssertEqual(GuestDragOutItems.fileName(#"C:\Users\tester\Documents\report.docx"#), "report.docx")
        XCTAssertEqual(GuestDragOutItems.fileName(#"C:\Users\tester\Pictures\Holiday"#), "Holiday")
        XCTAssertEqual(GuestDragOutItems.fileName("plain"), "plain")
    }

    func testNamesFromTheGuestCannotLeadElsewhere() {
        // A guest's answer is not trusted to name a single file (security review 2026-11-16).
        XCTAssertEqual(GuestDragOutItems.fileName(#"C:\Users\.."#), "file")
        XCTAssertEqual(GuestDragOutItems.fileName("."), "file")
        for bad in ["", ".", "..", "../x", "a/b", "../../.ssh/id_ed25519", "a\0b"] {
            XCTAssertFalse(GuestDragOutItems.isPlainName(bad), bad)
        }
        for good in ["report.docx", "..hidden", "a..b", "x y.txt"] {
            XCTAssertTrue(GuestDragOutItems.isPlainName(good), good)
        }
    }

    func testFetchTextIsIdThenOnePathPerLine() {
        let fetch = GuestDragOutFetch(id: "dragout-abc", paths: [#"C:\a b\x.txt"#, "bad\nline", #"C:\y"#])
        XCTAssertEqual(fetch.guestText, "dragout-abc\nC:\\a b\\x.txt\nC:\\y\n", "a path with a line break is left out rather than split")
        XCTAssertTrue(fetch.id.hasPrefix(GuestDragOutFetch.idPrefix))
    }

    func testItemsReportDecodes() throws {
        let json = #"{"x":120,"y":340,"paths":["C:\\Users\\t\\a.txt"]}"#
        let items = try JSONDecoder().decode(GuestDragOutItems.self, from: Data(json.utf8))
        XCTAssertEqual(items.paths, [#"C:\Users\t\a.txt"#])
        XCTAssertNil(items.message)
        let refused = try JSONDecoder().decode(GuestDragOutItems.self, from: Data(#"{"x":1,"y":2,"paths":[],"message":"no"}"#.utf8))
        XCTAssertEqual(refused.message, "no")
    }
}
