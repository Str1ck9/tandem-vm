import XCTest
@testable import Provisioning
import VMCore

final class LinuxTemplateTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-templates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func manifest(_ option: String = "ubuntu-24.04", checksum: String = "ABC123", recipe: Int = LinuxTemplateManifest.currentRecipe) -> LinuxTemplateManifest {
        LinuxTemplateManifest(option: option, title: "Ubuntu Server 24.04 LTS", imageURL: "https://example.invalid/u.img",
                              imageChecksum: checksum, recipe: recipe, buildSeconds: 42, diskGiB: 8)
    }

    private func install(_ m: LinuxTemplateManifest, in store: LinuxTemplateStore) throws {
        let disk = root.appendingPathComponent("built-\(UUID().uuidString).qcow2")
        try Data("disk".utf8).write(to: disk)
        try store.install(disk: disk, manifest: m)
    }

    func testManifestMatchesOnlyTheSameImageAndRecipe() {
        let m = manifest()
        XCTAssertTrue(m.matches(option: "ubuntu-24.04", imageChecksum: "abc123"), "checksums compare without case")
        XCTAssertFalse(m.matches(option: "ubuntu-26.04", imageChecksum: "abc123"))
        XCTAssertFalse(m.matches(option: "ubuntu-24.04", imageChecksum: "def456"), "a newer vendor image needs a new template")
        XCTAssertFalse(manifest(recipe: LinuxTemplateManifest.currentRecipe - 1).matches(option: "ubuntu-24.04", imageChecksum: "abc123"),
                       "an older recipe is rebuilt")
    }

    func testStoreInstallsListsSelectsAndDeletes() throws {
        let store = LinuxTemplateStore(libraryRoot: root)
        XCTAssertTrue(store.list().isEmpty)
        try install(manifest(), in: store)
        try install(manifest("kali", checksum: "FF"), in: store)
        XCTAssertEqual(store.list().map(\.manifest.option), ["kali", "ubuntu-24.04"])
        XCTAssertNotNil(store.usable(option: "ubuntu-24.04", imageChecksum: "abc123"))
        XCTAssertNil(store.usable(option: "ubuntu-24.04", imageChecksum: "000"), "stale templates are not used")
        XCTAssertEqual(store.entry(for: "kali")?.disk.lastPathComponent, "disk.qcow2")
        try store.delete(option: "kali")
        XCTAssertNil(store.entry(for: "kali"))
        XCTAssertThrowsError(try store.delete(option: "kali"))
        // The download cache's neighbour is the same store.
        XCTAssertEqual(LinuxTemplateStore(downloads: Downloader(cache: root.appendingPathComponent("Downloads"))).folder, store.folder)
    }

    func testAManifestWithoutItsDiskIsNotATemplate() throws {
        let store = LinuxTemplateStore(libraryRoot: root)
        try install(manifest(), in: store)
        try FileManager.default.removeItem(at: store.directory(for: "ubuntu-24.04").appendingPathComponent("disk.qcow2"))
        XCTAssertNil(store.entry(for: "ubuntu-24.04"))
        XCTAssertTrue(store.list().isEmpty)
    }

    func testTemplateSetupMakesNoAccountAndGeneralisesThenPowersOff() {
        for firstBoot in [LinuxSeed.FirstBoot.none, .ubuntuDesktop(.gnome), .ubuntuDesktop(.mate), .ubuntuDesktop(.xfce), .kali, .kaliDesktop] {
            let data = LinuxSeed.templateUserData(firstBoot: firstBoot)
            XCTAssertTrue(data.contains("users: []"), "no account on a template")
            XCTAssertFalse(data.contains("plain_text_passwd"))
            XCTAssertFalse(data.contains("systemctl reboot"), "a template powers off instead of restarting")
            XCTAssertTrue(data.contains("systemctl poweroff"))
            XCTAssertTrue(data.contains("cloud-init clean --logs --seed"))
            XCTAssertTrue(data.contains("truncate -s 0"), "machine id emptied")
            XCTAssertTrue(data.contains("ssh_host_"))
            XCTAssertTrue(data.contains("cloud-init.disabled"), "cloud-init runs again on clones")
            // Systems whose network Tandem configures itself keep cloud-init away from it on the clones.
            XCTAssertEqual(data.contains("network: {config: disabled}"), firstBoot != .none)
        }
        XCTAssertTrue(LinuxSeed.templateUserData(firstBoot: .ubuntuDesktop(.gnome)).contains("ubuntu-desktop-minimal"))
        XCTAssertTrue(LinuxSeed.templateUserData(firstBoot: .kaliDesktop).contains("kali-desktop-xfce"))
        XCTAssertFalse(LinuxSeed.templateUserData(firstBoot: .kali).contains("tandem-tools/install.sh"),
                       "guest tools are installed on each clone, not on the template")
    }

    func testCloneSetupMakesTheAccountAndNoSlowWork() {
        let withPassword = LinuxSeed.cloneUserData(hostName: "box", account: SystemAccount(userName: "alice", password: "pw"), desktop: false)
        XCTAssertTrue(withPassword.contains("plain_text_passwd: \"pw\""))
        XCTAssertTrue(withPassword.contains("hostname: \"box\""))
        XCTAssertTrue(withPassword.contains("install.sh"), "guest tools from the tools disc")
        XCTAssertTrue(withPassword.contains("--autologin alice"))
        XCTAssertFalse(withPassword.contains("apt-get"), "no first-boot installs on a clone")
        XCTAssertFalse(withPassword.contains("display-manager"))

        let desktop = LinuxSeed.cloneUserData(hostName: "box", account: SystemAccount(userName: "bob", password: ""), desktop: true)
        XCTAssertTrue(desktop.contains("passwd -d bob"))
        XCTAssertTrue(desktop.contains("NOPASSWD"))
        XCTAssertTrue(desktop.contains("AutomaticLogin=bob"))
        XCTAssertTrue(desktop.contains("systemctl restart display-manager"), "the display manager picks up the automatic sign-in")
    }

    func testTemplateDiskIsNeverSmallerThanTheOptionAllows() {
        let provider = LinuxCloudImages()
        let desktop = SystemOption(id: "ubuntu-desktop-24.04", title: "Ubuntu Desktop 24.04 LTS", detail: "")
        XCTAssertEqual(provider.templateGiB(for: desktop, imageGiB: 4), provider.defaults(for: desktop).minimumDiskGiB)
        let kali = SystemOption(id: "kali", title: "Kali", detail: "")
        XCTAssertEqual(provider.templateGiB(for: kali, imageGiB: 25), 25)
    }

    func testConsoleProgressLineDropsTerminalCodes() throws {
        let log = root.appendingPathComponent("console.log")
        try Data("[  OK  ] Started x\r\n\u{1B}[0;32mUnpacking firefox (1.0) ...\u{1B}[0m\r\n".utf8).write(to: log)
        XCTAssertEqual(LinuxCloudImages.lastConsoleLine(log), "Unpacking firefox (1.0) ...")
    }
}
