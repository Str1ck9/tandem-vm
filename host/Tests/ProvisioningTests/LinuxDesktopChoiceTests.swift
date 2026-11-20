import XCTest
@testable import Provisioning
import VMCore

/// Ubuntu Desktop with a choice of MATE, Xfce or GNOME.
final class LinuxDesktopChoiceTests: XCTestCase {
    private let a = String(repeating: "a", count: 64)

    func testEachReleaseOffersThreeDesktopsOfOneGroup() throws {
        let server = try XCTUnwrap(LinuxCloudImages.ubuntu("24.04", sums: "\(a) *ubuntu-24.04-server-cloudimg-arm64.img"))
        let images = LinuxDesktop.allCases.map { LinuxCloudImages.ubuntuDesktop(from: server, release: "24.04", desktop: $0) }
        XCTAssertEqual(images.map(\.option.id), ["ubuntu-desktop-mate-24.04", "ubuntu-desktop-xfce-24.04", "ubuntu-desktop-24.04"],
                       "GNOME keeps its old ID, so templates made before the choice still match")
        XCTAssertEqual(Set(images.map(\.option.variantGroup)), ["ubuntu-desktop-24.04"])
        XCTAssertEqual(images.map(\.option.variant), ["MATE", "Xfce", "GNOME"])
        XCTAssertEqual(Set(images.map(\.url)), [server.url], "one download serves every desktop")
        XCTAssertEqual(images.map(\.firstBoot), [.ubuntuDesktop(.mate), .ubuntuDesktop(.xfce), .ubuntuDesktop(.gnome)])
        XCTAssertEqual(LinuxDesktop.allCases.first, LinuxDesktop.standard, "MATE is listed first and is the default")
        for image in images { XCTAssertTrue(image.option.title.contains(image.option.variant!)) }
    }

    func testTheListShowsEachDesktopGroupOnceAsThePreferredDesktop() {
        let server = SystemOption(id: "ubuntu-24.04", title: "Ubuntu Server", detail: "")
        let desktops = LinuxDesktop.allCases.map {
            SystemOption(id: $0.optionID(release: "24.04"), title: $0.title, detail: "", variantGroup: "ubuntu-desktop-24.04", variant: $0.title)
        }
        let all = desktops + [server]
        XCTAssertEqual(SystemOption.listing(all, preferring: nil, selected: nil).map(\.id), ["ubuntu-desktop-mate-24.04", "ubuntu-24.04"])
        XCTAssertEqual(SystemOption.listing(all, preferring: "Xfce", selected: nil).map(\.id), ["ubuntu-desktop-xfce-24.04", "ubuntu-24.04"])
        XCTAssertEqual(SystemOption.listing(all, preferring: "Xfce", selected: desktops[2]).map(\.id), ["ubuntu-desktop-24.04", "ubuntu-24.04"],
                       "the flavour picked in the list wins")
        XCTAssertEqual(SystemOption.listing(all, preferring: "Nonexistent", selected: server).map(\.id), ["ubuntu-desktop-mate-24.04", "ubuntu-24.04"])
        XCTAssertEqual(SystemOption.listing([server], preferring: "MATE", selected: nil), [server], "ungrouped options are untouched")
    }

    func testOptionIDsMapBackToTheirDesktop() {
        XCTAssertEqual(LinuxDesktop.from(optionID: "ubuntu-desktop-mate-26.04"), .mate)
        XCTAssertEqual(LinuxDesktop.from(optionID: "ubuntu-desktop-xfce-24.04"), .xfce)
        XCTAssertEqual(LinuxDesktop.from(optionID: "ubuntu-desktop-24.04"), .gnome)
        XCTAssertNil(LinuxDesktop.from(optionID: "ubuntu-24.04"))
        for desktop in LinuxDesktop.allCases {
            XCTAssertEqual(LinuxDesktop.from(optionID: desktop.optionID(release: "26.04")), desktop)
        }
    }

    func testEveryDesktopGetsDesktopDefaults() {
        let provider = LinuxCloudImages()
        let server = provider.defaults(for: SystemOption(id: "ubuntu-24.04", title: "U", detail: ""))
        for desktop in LinuxDesktop.allCases {
            let d = provider.defaults(for: SystemOption(id: desktop.optionID(release: "24.04"), title: "U", detail: ""))
            XCTAssertGreaterThan(d.memoryMiB, server.memoryMiB, desktop.title)
            XCTAssertGreaterThanOrEqual(d.minimumDiskGiB, 32, desktop.title)
        }
    }

    func testLightDMDesktopsInstallTheirX11SessionAndSignInAutomatically() throws {
        let account = SystemAccount(userName: "tester", password: "pw")
        for (desktop, core, session, greeter) in [(LinuxDesktop.mate, "ubuntu-mate-core", "user-session=mate", "slick-greeter"),
                                                   (.xfce, "xubuntu-core", "user-session=%s", "lightdm-gtk-greeter")] {
            let data = LinuxSeed.userData(hostName: "box", account: account, firstBoot: .ubuntuDesktop(desktop))
            let runcmds = data.components(separatedBy: "\n").filter { $0.hasPrefix("  - [sh, -c,") }
            let install = try XCTUnwrap(runcmds.firstIndex { $0.contains(core) }, desktop.title)
            let line = runcmds[install]
            XCTAssertTrue(line.contains("lightdm"), desktop.title)
            XCTAssertTrue(line.contains(greeter), desktop.title)
            XCTAssertTrue(line.contains("xserver-xorg") && line.contains("xclip") && line.contains("x11-xserver-utils"), desktop.title)
            XCTAssertTrue(line.contains("firefox"), desktop.title)
            XCTAssertTrue(line.contains(session), desktop.title)
            // LightDM is chosen before the packages arrive, so the install never stops to ask.
            let preseed = try XCTUnwrap(line.range(of: "shared/default-x-display-manager select lightdm"), desktop.title)
            let packages = try XCTUnwrap(line.range(of: "apt-get update"), desktop.title)
            XCTAssertLessThan(preseed.lowerBound, packages.lowerBound, desktop.title)
            XCTAssertFalse(line.contains("ubuntu-desktop-minimal"), "no GNOME with \(desktop.title)")
            XCTAssertFalse(line.contains("gdm3"), desktop.title)
            XCTAssertTrue(line.contains("renderer: NetworkManager"), "the same network hand-over as GNOME")
            XCTAssertTrue(line.contains("graphical.target"), desktop.title)
            // Seen live: Ubuntu MATE's greeter turns guest sessions on and offers the next release.
            XCTAssertTrue(line.contains("99-tandem-session.conf") && line.contains("allow-guest=false"), desktop.title)
            XCTAssertTrue(line.contains("Prompt=never"), desktop.title)
            XCTAssertTrue(line.contains("TANDEM_TOOLS") && line.contains("UDISKS_IGNORE"), "the tools disc stays off the desktop")
            // Automatic sign-in after the install, before the restart.
            let signIn = try XCTUnwrap(runcmds.firstIndex { $0.contains("autologin-user=tester") }, desktop.title)
            XCTAssertGreaterThan(signIn, install, desktop.title)
            XCTAssertTrue(runcmds.last?.contains("systemctl reboot") == true, desktop.title)
        }
    }

    func testGNOMEIsUnchanged() {
        let data = LinuxSeed.userData(hostName: "box", account: SystemAccount(userName: "tester", password: "pw"), firstBoot: .ubuntuDesktop(.gnome))
        XCTAssertTrue(data.contains("install ubuntu-desktop-minimal xclip x11-xserver-utils"))
        XCTAssertTrue(data.contains("WaylandEnable=false"))
        XCTAssertFalse(data.contains("default-x-display-manager"))
        XCTAssertFalse(data.contains("ubuntu-mate-core") || data.contains("xubuntu-core"))
    }

    func testTemplatesDoTheDesktopWorkOncePerDesktop() {
        for desktop in [LinuxDesktop.mate, .xfce] {
            let data = LinuxSeed.templateUserData(firstBoot: .ubuntuDesktop(desktop))
            XCTAssertTrue(data.contains(desktop == .mate ? "ubuntu-mate-core" : "xubuntu-core"))
            XCTAssertTrue(data.contains("network: {config: disabled}"), "Tandem wrote the network settings")
            XCTAssertFalse(data.contains("autologin-user"), "no account in a template")
        }
        // Clones of a LightDM desktop get automatic sign-in and a display-manager restart.
        let clone = LinuxSeed.cloneUserData(hostName: "box", account: SystemAccount(userName: "bob", password: "pw"), desktop: true)
        XCTAssertTrue(clone.contains("autologin-user=bob"))
        XCTAssertTrue(clone.contains("systemctl restart display-manager"))
        XCTAssertEqual(LinuxCloudImages.buildTimeout(.ubuntuDesktop(.mate)), LinuxCloudImages.buildTimeout(.ubuntuDesktop(.gnome)))
    }

    func testTemplateStoreKeepsDesktopsApart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-desk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LinuxTemplateStore(libraryRoot: root)
        let ids = Set(LinuxDesktop.allCases.map { store.directory(for: $0.optionID(release: "24.04")).path })
        XCTAssertEqual(ids.count, 3, "each desktop has a template of its own")
        XCTAssertEqual(store.directory(for: LinuxDesktop.gnome.optionID(release: "24.04")).lastPathComponent, "ubuntu-desktop-24.04",
                       "the GNOME template made before the choice is still found")
    }

    /// Every desktop's user data is valid YAML for cloud-init (libyaml through the system Ruby).
    func testUserDataParsesForEveryDesktop() throws {
        let ruby = URL(fileURLWithPath: "/usr/bin/ruby")
        guard FileManager.default.isExecutableFile(atPath: ruby.path),
              (try? ToolRun.run(ruby, ["-ryaml", "-e", "1"], timeout: 30))?.succeeded == true else {
            throw XCTSkip("no Ruby with YAML on this Mac")
        }
        for desktop in LinuxDesktop.allCases {
            for text in [LinuxSeed.userData(hostName: "box", account: SystemAccount(userName: "tester", password: "p'w\"x"), firstBoot: .ubuntuDesktop(desktop)),
                         LinuxSeed.templateUserData(firstBoot: .ubuntuDesktop(desktop))] {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-desk-\(UUID().uuidString).yaml")
                try Data(text.utf8).write(to: file)
                defer { try? FileManager.default.removeItem(at: file) }
                let script = "d = YAML.safe_load(File.read(ARGV[0])); c = d['runcmd'].map { |r| r[2] }.join(\"\\n\"); puts(c.include?('apt-get') ? 'ok' : 'missing')"
                let result = try ToolRun.run(ruby, ["-ryaml", "-e", script, file.path], timeout: 30)
                XCTAssertTrue(result.succeeded, "\(desktop.title): \(result.errorText)")
                XCTAssertEqual(result.outputText.trimmingCharacters(in: .whitespacesAndNewlines), "ok", desktop.title)
            }
        }
    }
}
