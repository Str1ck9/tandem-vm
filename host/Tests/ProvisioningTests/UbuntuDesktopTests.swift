import XCTest
@testable import Provisioning
import VMCore

final class UbuntuDesktopTests: XCTestCase {
    private let a = String(repeating: "a", count: 64)

    func testTheDesktopComesFromTheServerImage() throws {
        let server = try XCTUnwrap(LinuxCloudImages.ubuntu("26.04", sums: "\(a) *ubuntu-26.04-server-cloudimg-arm64.img"))
        let desktop = LinuxCloudImages.ubuntuDesktop(from: server, release: "26.04")
        XCTAssertEqual(desktop.option.id, "ubuntu-desktop-26.04")
        XCTAssertEqual(desktop.option.title, "Ubuntu Desktop 26.04 LTS (GNOME)")
        XCTAssertEqual(desktop.url, server.url, "one download serves both")
        XCTAssertEqual(desktop.checksum, server.checksum)
        XCTAssertEqual(desktop.firstBoot, .ubuntuDesktop(.gnome))
        XCTAssertEqual(server.firstBoot, .none, "the server choice is unchanged")
        XCTAssertFalse(desktop.option.detail.contains("@"), "the measured time is filled in")
    }

    func testTheDesktopGetsMoreRoomAndMemory() {
        let provider = LinuxCloudImages()
        let server = provider.defaults(for: SystemOption(id: "ubuntu-26.04", title: "Ubuntu", detail: ""))
        let desktop = provider.defaults(for: SystemOption(id: "ubuntu-desktop-26.04", title: "Ubuntu", detail: ""))
        XCTAssertGreaterThan(desktop.diskGiB, server.diskGiB)
        XCTAssertGreaterThan(desktop.memoryMiB, server.memoryMiB)
        XCTAssertGreaterThanOrEqual(desktop.minimumDiskGiB, 32)
    }

    func testFirstBootInstallsTheDesktopOnX11ThenRestarts() throws {
        // Automatic sign-in switched off here; AccountSignInTests covers it switched on (the default).
        let account = SystemAccount(userName: "tester", password: "pw", autoLogin: false)
        let data = LinuxSeed.userData(hostName: "ubuntu", account: account, firstBoot: .ubuntuDesktop(.gnome))
        let tools = try XCTUnwrap(data.range(of: "install.sh"), "guest tools from the tools disc, as for the server")
        let desktop = try XCTUnwrap(data.range(of: "ubuntu-desktop-minimal"))
        let reboot = try XCTUnwrap(data.range(of: "systemctl reboot"))
        XCTAssertTrue(tools.lowerBound < desktop.lowerBound && desktop.lowerBound < reboot.lowerBound)
        XCTAssertTrue(data.contains("WaylandEnable=false"), "the guest tools need X for clipboard and resizing")
        XCTAssertTrue(data.contains("xclip"))
        XCTAssertTrue(data.contains("graphical.target"))
        XCTAssertFalse(data.contains("AutomaticLoginEnable"), "nobody is signed in automatically when it is switched off")
        XCTAssertFalse(data.contains("linux-image-arm64"), "Ubuntu's cloud image already has the full kernel")
        XCTAssertFalse(LinuxSeed.FirstBoot.ubuntuDesktop(.gnome).toolsOnSeed, "the tools disc works on Ubuntu")
    }
}
