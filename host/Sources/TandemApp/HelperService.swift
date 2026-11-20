import AppKit
import Foundation
import ServiceManagement
import NetHelperClient
import VMCore

/// The Tandem helper installed the macOS way: a packaged, Developer ID–signed Tandem.app carries the
/// helper and its launch file (`Contents/Library/LaunchDaemons/<prefix>.helper.plist`),
/// registers it with SMAppService, and the user approves it once in System Settings > General > Login Items.
/// No administrator password, no files written outside the app, and an update of the app updates the
/// helper with it. Development builds (ad hoc signed) keep using scripts/install-net-helper.sh.
enum HelperService {
    static let plistName = TandemIdentity.helperPlistName
    /// The daemon the installer script puts in /Library/LaunchDaemons. It serves the same socket as the
    /// in-app helper, so only one of the two may be installed.
    static var legacyPlists: [String] { ["/Library/LaunchDaemons/\(TandemIdentity.scriptHelper).plist"] }

    static var service: SMAppService { .daemon(plistName: plistName) }

    /// True when this copy of Tandem can install its helper itself: it carries the launch file and the
    /// helper, and is signed by a developer team (SMAppService refuses ad hoc signed apps).
    static var isAvailable: Bool {
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        let plist = contents.appendingPathComponent("Library/LaunchDaemons/\(plistName)")
        let helper = contents.appendingPathComponent("Helpers/TandemNetHelper")
        return FileManager.default.fileExists(atPath: plist.path)
            && FileManager.default.isExecutableFile(atPath: helper.path)
            && appTeamIdentifier != nil
    }

    static var legacyInstalled: Bool { legacyPlists.contains { FileManager.default.fileExists(atPath: $0) } }

    /// The team that signed the running app; nil when it is signed ad hoc.
    static var appTeamIdentifier: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// One line for the settings, or nil when this build installs the helper with the script.
    static var statusText: String? {
        guard isAvailable else { return nil }
        switch service.status {
        case .enabled: return "Installed from this copy of Tandem"
        case .requiresApproval: return "Waiting for your approval in System Settings > General > Login Items"
        case .notRegistered: return legacyInstalled ? "Installed with the older script" : "Not installed"
        case .notFound: return "This copy of Tandem cannot install its helper"
        @unknown default: return nil
        }
    }

    /// Registers the helper. If macOS wants the user's approval, opens the place to give it.
    static func register() throws {
        if legacyInstalled {
            throw VMError("An older Tandem helper, installed with the script, is still present.",
                          detail: "Remove it first in Terminal, from the folder Tandem was built in:\nsudo scripts/install-net-helper.sh --uninstall\nthen install again here.")
        }
        do {
            try service.register()
        } catch {
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                throw VMError("Approve the Tandem helper in System Settings.",
                              detail: "System Settings > General > Login Items has opened: switch on Tandem under “Allow in the Background”. USB drives then also need Full Disk Access: switch on “Tandem” itself in Privacy & Security > Full Disk Access.")
            }
            throw VMError("The Tandem helper could not be installed.", detail: error.localizedDescription)
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            throw VMError("Approve the Tandem helper in System Settings.",
                          detail: "System Settings > General > Login Items has opened: switch on Tandem under “Allow in the Background”.")
        }
    }

    static func unregister() throws { try service.unregister() }

    /// System Settings > Privacy & Security > Full Disk Access.
    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    static func openFullDiskAccess() { NSWorkspace.shared.open(fullDiskAccessURL) }

    static func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    /// Starts the helper afresh, which is how it picks up a Full Disk Access grant given after it started.
    /// The helper refuses while it serves a VM.
    static func restartHelper() throws {
        let status = try NetHelper.status()
        if status.canRestart {
            try NetHelper.restart()
            return
        }
        if status.fromBundle != false, isAvailable, service.status == .enabled {
            openLoginItems()
            throw VMError("This helper is too old to restart itself.",
                          detail: "In System Settings > General > Login Items (now open), switch Tandem off and on again under “Allow in the Background”. The next version of the helper restarts from here.")
        }
        throw VMError("This helper is too old to restart itself.",
                      detail: "In Terminal: sudo launchctl kickstart -k system/\(TandemIdentity.scriptHelper)")
    }
}
