import XCTest
@testable import Provisioning
import VMCore

final class KaliTests: XCTestCase {
    private let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64), c = String(repeating: "c", count: 64)

    func testListingGivesTheNewestArm64CloudImageTwice() throws {
        let sums = """
        \(a)  kali-linux-2026.2-cloud-genericcloud-arm64.tar.xz
        \(b)  kali-linux-2026.3-cloud-genericcloud-amd64.tar.xz
        \(c) *kali-linux-2026.10-cloud-genericcloud-arm64.tar.xz
        \(b)  kali-linux-2026.10-cloud-genericcloud-arm64.tar.xz.torrent
        """
        let images = LinuxCloudImages.kali(sums: sums)
        XCTAssertEqual(images.map(\.option.id), ["kali", "kali-desktop"])
        XCTAssertEqual(images[0].url.lastPathComponent, "kali-linux-2026.10-cloud-genericcloud-arm64.tar.xz", "2026.10 is newer than 2026.2")
        XCTAssertEqual(images[0].checksum, .sha256(c))
        XCTAssertEqual(images[0].url, images[1].url, "both choices come from one download")
        XCTAssertEqual(images[0].firstBoot, .kali)
        XCTAssertEqual(images[1].firstBoot, .kaliDesktop)
        XCTAssertEqual(images[0].option.title, "Kali Linux 2026.10")
        XCTAssertTrue(LinuxCloudImages.kali(sums: "\(b)  kali-linux-2026.3-cloud-genericcloud-amd64.tar.xz").isEmpty, "Intel only: nothing offered")
        XCTAssertTrue(LinuxCloudImages.kali(sums: "short  kali-linux-2026.3-cloud-genericcloud-arm64.tar.xz").isEmpty)
    }

    func testTheDesktopGetsMoreRoomAndMemory() {
        let provider = LinuxCloudImages()
        let plain = provider.defaults(for: SystemOption(id: "kali", title: "Kali", detail: ""))
        let desktop = provider.defaults(for: SystemOption(id: "kali-desktop", title: "Kali", detail: ""))
        XCTAssertGreaterThan(desktop.diskGiB, plain.diskGiB)
        XCTAssertGreaterThan(desktop.memoryMiB, plain.memoryMiB)
        XCTAssertGreaterThanOrEqual(desktop.minimumDiskGiB, 32)
    }

    func testFirstBootInstallsToolsFromTheSetupDiscThenTheFullKernelThenRestarts() {
        let account = SystemAccount(userName: "tester", password: "pw")
        let plain = LinuxSeed.userData(hostName: "kali", account: account, firstBoot: .kali)
        let tools = try! XCTUnwrap(plain.range(of: "blkid -L cidata"))
        let kernel = try! XCTUnwrap(plain.range(of: "linux-image-arm64"))
        let reboot = try! XCTUnwrap(plain.range(of: "systemctl reboot"))
        XCTAssertTrue(tools.lowerBound < kernel.lowerBound && kernel.lowerBound < reboot.lowerBound)
        XCTAssertTrue(plain.contains("getty@tty1.service.d") && plain.contains("autologin.conf"), "the console must not sign in as root by itself"); XCTAssertTrue(plain.contains("20-tandem-wired.network"), "the network must survive cloud-init being switched off")
        XCTAssertFalse(plain.contains("kali-desktop-xfce"))
        let desktop = LinuxSeed.userData(hostName: "kali", account: account, firstBoot: .kaliDesktop)
        XCTAssertTrue(desktop.contains("kali-desktop-xfce") && desktop.contains("graphical.target"))
        XCTAssertFalse(LinuxSeed.userData(hostName: "x", account: account).contains("linux-image-arm64"), "other systems are unchanged")
    }

    func testTheArchivedDiskIsFoundAndStaysSparse() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("kali-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        let content = work.appendingPathComponent("content")
        try fm.createDirectory(at: content, withIntermediateDirectories: true)
        // A 1 GiB disk with one byte written: sparse, like Kali's 25 GiB disk.raw.
        let disk = content.appendingPathComponent("disk.raw")
        fm.createFile(atPath: disk.path, contents: nil)
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: 1 << 30)
        try handle.seek(toOffset: 4096)
        try handle.write(contentsOf: Data([1]))
        try handle.close()
        try Data("notes".utf8).write(to: content.appendingPathComponent("README"))
        let archive = work.appendingPathComponent("image.tar.xz")
        try LinuxCloudImages.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-cJSf", archive.path, "-C", content.path, "disk.raw", "README"])

        let found = try LinuxCloudImages.unpackDisk(archive, into: work.appendingPathComponent("out"))
        XCTAssertEqual(found.lastPathComponent, "disk.raw")
        let values = try found.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        XCTAssertEqual(values.fileSize, 1 << 30)
        XCTAssertLessThan(values.totalFileAllocatedSize ?? .max, 64 << 20, "the unpacked disk must stay sparse")

        let empty = work.appendingPathComponent("empty.tar.xz")
        try LinuxCloudImages.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-cJf", empty.path, "-C", content.path, "README"])
        XCTAssertThrowsError(try LinuxCloudImages.unpackDisk(empty, into: work.appendingPathComponent("out2")))
    }
}
