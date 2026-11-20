import XCTest
@testable import Provisioning
import VMCore

/// Optional passwords and automatic sign-in in the set-up Tandem writes for new systems.
final class AccountSignInTests: XCTestCase {
    // MARK: Linux

    func testPasswordlessAccountHasNoPasswordAndSudoWithoutOne() {
        let data = LinuxSeed.userData(hostName: "box", account: SystemAccount(userName: "tester", password: ""), firstBoot: .none)
        XCTAssertFalse(data.contains("plain_text_passwd"))
        XCTAssertTrue(data.contains("sudo: \"ALL=(ALL) NOPASSWD:ALL\""))
        XCTAssertTrue(data.contains("passwd -d tester"))
        XCTAssertTrue(data.contains("PermitEmptyPasswords no"), "remote logins with an empty password stay refused")
    }

    func testPasswordedAccountKeepsPasswordAndSudoAsks() {
        let data = LinuxSeed.userData(hostName: "box", account: SystemAccount(userName: "tester", password: "pw"), firstBoot: .none)
        XCTAssertTrue(data.contains("plain_text_passwd: \"pw\""))
        XCTAssertTrue(data.contains("sudo: \"ALL=(ALL) ALL\""))
        XCTAssertFalse(data.contains("passwd -d"))
    }

    func testServerAutoLoginUsesTheConsolesAndCanBeOff() {
        let on = LinuxSeed.userData(hostName: "box", account: SystemAccount(userName: "tester", password: "pw"), firstBoot: .kali)
        XCTAssertTrue(on.contains("agetty --autologin tester"))
        XCTAssertTrue(on.contains("serial-getty@ttyAMA0"))
        XCTAssertFalse(on.contains("AutomaticLogin"), "no display manager on a server image")
        let off = LinuxSeed.userData(hostName: "box", account: SystemAccount(userName: "tester", password: "pw", autoLogin: false), firstBoot: .kali)
        XCTAssertFalse(off.contains("--autologin"))
    }

    func testDesktopAutoLoginGoesToTheDisplayManagerBeforeTheRestart() {
        let data = LinuxSeed.userData(hostName: "box", account: SystemAccount(userName: "tester", password: ""), firstBoot: .ubuntuDesktop(.gnome))
        XCTAssertTrue(data.contains("AutomaticLogin=tester"))
        XCTAssertTrue(data.contains("autologin-user=tester"), "LightDM too, for Kali's desktop")
        XCTAssertFalse(data.contains("agetty --autologin"))
        // The restart must stay last, or the sign-in set-up would never run.
        let runcmds = data.components(separatedBy: "\n").filter { $0.hasPrefix("  - [sh, -c,") }
        XCTAssertTrue(runcmds.last?.contains("systemctl reboot") == true)
        let signIn = runcmds.firstIndex { $0.contains("AutomaticLogin") }
        let install = runcmds.firstIndex { $0.contains("ubuntu-desktop-minimal") }
        XCTAssertNotNil(signIn); XCTAssertNotNil(install)
        if let signIn, let install { XCTAssertGreaterThan(signIn, install, "sign-in is set after the desktop is installed") }
    }

    func testLinuxProviderAcceptsAnEmptyPassword() {
        XCTAssertTrue(LinuxCloudImages().accountProblems(SystemAccount(userName: "tester", password: "")).isEmpty)
        XCTAssertFalse(LinuxCloudImages().accountProblems(SystemAccount(userName: "root", password: "")).isEmpty)
    }

    // MARK: Windows

    func testWindowsAutoLoginPersistsThroughTheRegistry() {
        let o = WindowsUnattendOptions(userName: "tester", password: "it's")
        let script = AutounattendBuilder.firstLogonScript(for: o)
        XCTAssertTrue(script.contains("AutoAdminLogon -Value '1'"))
        XCTAssertTrue(script.contains("DefaultUserName -Value 'tester'"))
        XCTAssertTrue(script.contains("DefaultPassword -Value 'it''s'"), "single quotes are doubled for PowerShell")
        XCTAssertTrue(script.contains("Remove-ItemProperty -Path $winlogon -Name AutoLogonCount"))
        XCTAssertTrue(script.hasSuffix("Stop-Transcript | Out-Null"), "the transcript still closes last")
    }

    func testWindowsWithoutAutoLoginKeepsTheCommonScript() {
        var o = WindowsUnattendOptions(userName: "tester", password: "pw")
        o.autoLogin = false
        XCTAssertEqual(AutounattendBuilder.firstLogonScript(for: o), AutounattendBuilder.firstLogonScript)
        XCTAssertFalse(AutounattendBuilder.firstLogonScript(for: o).contains("AutoAdminLogon"))
    }

    func testWindowsMediaCarriesTheScriptForTheseAnswers() throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-signin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try UnattendMediaBuilder.stage(.init(options: WindowsUnattendOptions(userName: "u", password: "")), in: staging)
        let script = String(decoding: try Data(contentsOf: staging.appendingPathComponent("firstlogon.ps1")), as: UTF8.self)
        XCTAssertTrue(script.contains("AutoAdminLogon"))
        XCTAssertTrue(script.contains("DefaultPassword -Value ''"), "an empty password signs in too")
    }
}
