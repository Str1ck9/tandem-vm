import XCTest
@testable import VMCore

final class GuestIntegrationTests: XCTestCase {
    private func config(_ os: GuestOS, _ engine: EngineKind) -> VMConfig { VMConfig(name: "t", guestOS: os, engine: engine) }

    func testWindowsAndQEMULinuxHaveGuestPrograms() {
        XCTAssertTrue(config(.windows11arm, .qemu).supportsGuestPrograms)
        XCTAssertTrue(config(.linux, .qemu).supportsGuestPrograms)
        XCTAssertFalse(config(.linux, .vz).supportsGuestPrograms, "Linux on Apple's engine has no guest tools for this yet")
        XCTAssertFalse(config(.macos, .vz).supportsGuestPrograms)
        XCTAssertTrue(config(.linux, .qemu).supportsGuestFileDrop)
        XCTAssertFalse(config(.macos, .vz).supportsGuestFileDrop)
    }

    func testLinuxSeamlessIsOffUntilTheUserTurnsItOn() {
        XCTAssertTrue(config(.windows11arm, .qemu).supportsSeamless(linuxEnabled: false))
        XCTAssertFalse(config(.linux, .qemu).supportsSeamless(linuxEnabled: false))
        XCTAssertTrue(config(.linux, .qemu).supportsSeamless(linuxEnabled: true))
        XCTAssertFalse(config(.linux, .vz).supportsSeamless(linuxEnabled: true))
        XCTAssertFalse(config(.macos, .vz).supportsSeamless(linuxEnabled: true))
    }

    func testGuestSystemWord() {
        XCTAssertEqual(config(.linux, .qemu).guestSystemWord, "Linux")
        XCTAssertEqual(config(.windows11arm, .qemu).guestSystemWord, "Windows")
    }

    func testFileManagerClasses() {
        for name in ["Caja", "Thunar", "Nautilus", "org.gnome.Nautilus", "Nemo", "Pcmanfm", "dolphin"] {
            XCTAssertTrue(GuestIntegration.isLinuxFileManager(name), name)
        }
        for name in ["Firefox", "Pluma", "", "xterm", "Filesystem"] { XCTAssertFalse(GuestIntegration.isLinuxFileManager(name), name) }
    }
}
