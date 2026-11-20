import XCTest
@testable import VMCore

/// Review finding R19: free space is checked where the data goes, and an unknown capacity is not "zero".
final class FreeSpaceTests: XCTestCase {
    func testTheDestinationVolumeIsTheOneMeasured() throws {
        let library = URL(fileURLWithPath: "/Volumes/Small/Library")
        let vms = URL(fileURLWithPath: "/Volumes/Big/VMs")
        let capacity: (URL) -> Int64? = { $0.path.hasPrefix("/Volumes/Big") ? 500 << 30 : 1 << 30 }
        XCTAssertNoThrow(try FreeSpace.require(100 << 30, at: vms, for: "A full copy", capacity: capacity))
        XCTAssertThrowsError(try FreeSpace.require(100 << 30, at: library, for: "A full copy", capacity: capacity)) { error in
            XCTAssertTrue((error as? VMError)?.detail == library.path)
        }
    }

    func testUnknownCapacityDoesNotBlock() {
        XCTAssertNoThrow(try FreeSpace.require(1 << 40, at: URL(fileURLWithPath: "/nowhere"), for: "x", capacity: { _ in nil }))
    }

    func testAMissingFolderIsMeasuredAtItsParent() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)/VMs")
        XCTAssertNotNil(FreeSpace.available(at: missing))
        XCTAssertGreaterThan(FreeSpace.available(at: missing) ?? 0, 0)
    }
}
