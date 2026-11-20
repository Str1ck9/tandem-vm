import Darwin
import Foundation
import Security
import VMCore

/// Puts a downloaded, verified update in place of the installed Tandem.app.
///
/// 1. `stage`: the new app is copied out of the archive into a hidden folder next to the installed one
///    (same volume, so the swap is one rename), and checked: a valid code signature from the same
///    developer team as the installed app, Tandem's identifier, and exactly the version the signed release
///    names, newer than the installed one.
/// 2. `install`: the two folders are swapped in one atomic rename (`RENAME_SWAP`): at every moment there
///    is a complete Tandem.app at the old path. The old copy then goes to the Trash.
public enum UpdateInstaller {
    public static let bundleIdentifier = TandemIdentity.app

    public struct Staged: Sendable {
        public var app: URL
        public var target: URL
        public var version: AppVersion
        public var team: String
        var folder: URL
    }

    public enum OldCopy: Sendable { case trash, delete }

    // MARK: Stage

    public static func stage(archive: URL, release: UpdateRelease, replacing target: URL) throws -> Staged {
        let fm = FileManager.default
        let target = target.standardizedFileURL
        guard fm.fileExists(atPath: target.appendingPathComponent("Contents/Info.plist").path) else {
            throw VMError("Tandem is not where the update would go.", detail: target.path)
        }
        guard let installedInfo = NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let installed = AppVersion.of(info: installedInfo) else {
            throw VMError("The installed Tandem’s version could not be read.", detail: target.path)
        }
        guard release.appVersion > installed else { throw UpdateClient.notNewer(release, installed) }
        guard let team = try teamIdentifier(of: target) else {
            throw VMError("This copy of Tandem is not signed by a developer, so Tandem cannot tell that an update comes from the same one.",
                          detail: "Development builds are updated by building them again.")
        }
        let parent = target.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else {
            throw VMError("Tandem cannot replace itself in \(parent.path).",
                          detail: "Your account cannot write there. Open the downloaded disk image and drag Tandem to \(parent.lastPathComponent) yourself.")
        }
        let folder = parent.appendingPathComponent(".Tandem-update-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        do {
            let app = folder.appendingPathComponent(target.lastPathComponent, isDirectory: true)
            try extract(archive, to: app)
            try checkSignature(of: app, team: team)
            guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
                  info["CFBundleIdentifier"] as? String == bundleIdentifier, let version = AppVersion.of(info: info) else {
                throw VMError("The update does not contain Tandem.")
            }
            guard version == release.appVersion else {
                throw VMError("The update contains Tandem \(version), not \(release.appVersion) as signed.", detail: "It is not installed.")
            }
            guard version > installed else { throw UpdateClient.notNewer(release, installed) }
            return Staged(app: app, target: target, version: version, team: team, folder: folder)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    /// Copies Tandem.app out of a disk image or a zip into `destination` (which must not exist yet).
    static func extract(_ archive: URL, to destination: URL) throws {
        let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
        switch archive.pathExtension.lowercased() {
        case "zip":
            let unpacked = destination.deletingLastPathComponent().appendingPathComponent(".unzipped", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: unpacked) }
            try ToolRun.checked(ditto, ["-x", "-k", archive.path, unpacked.path], timeout: ToolRun.Limit.image, failure: "The update could not be unpacked.")
            let app = try findApp(in: unpacked)
            try FileManager.default.moveItem(at: app, to: destination)
        default:
            let mount = try attach(archive)
            defer { detach(mount) }
            let app = try findApp(in: mount)
            try ToolRun.checked(ditto, [app.path, destination.path], timeout: ToolRun.Limit.image, failure: "The update could not be copied from its disk image.")
        }
    }

    private static func findApp(in folder: URL) throws -> URL {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
        let apps = items.filter { $0.pathExtension == "app" && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
        if let tandem = apps.first(where: { (Bundle(url: $0)?.bundleIdentifier) == bundleIdentifier }) { return tandem }
        throw VMError("The update does not contain Tandem.")
    }

    static let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")

    private static func attach(_ image: URL) throws -> URL {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-update-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let result = try ToolRun.run(hdiutil, ["attach", "-nobrowse", "-readonly", "-noautoopen", "-noverify", "-mountpoint", mount.path, image.path],
                                     timeout: ToolRun.Limit.image)
        guard result.succeeded else {
            try? FileManager.default.removeItem(at: mount)
            throw ToolRun.failed(result, "The update’s disk image could not be opened.")
        }
        return mount
    }

    private static func detach(_ mount: URL) {
        if (try? ToolRun.run(hdiutil, ["detach", mount.path], timeout: ToolRun.Limit.quick).succeeded) != true {
            _ = try? ToolRun.run(hdiutil, ["detach", "-force", mount.path], timeout: ToolRun.Limit.quick)
        }
        try? FileManager.default.removeItem(at: mount)
    }

    // MARK: Code signatures

    /// The developer team that signed an app; nil when it is signed ad hoc or not at all.
    public static func teamIdentifier(of app: URL) throws -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The requirement an update must meet: signed through Apple's developer programme, by `team`, as Tandem.
    public static func requirement(team: String) -> String {
        "anchor apple generic and identifier \"\(bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// Throws unless `app` and everything inside it is validly signed by `team` as Tandem.
    public static func checkSignature(of app: URL, team: String) throws {
        guard team.allSatisfy({ $0.isLetter || $0.isNumber }), !team.isEmpty else { throw VMError("Not a developer team: \(team)") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw VMError("The update is not a signed app.")
        }
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(Self.requirement(team: team) as CFString, [], &compiled) == errSecSuccess, let compiled else {
            throw VMError("The signing requirement could not be made.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, compiled, &error)
        guard status == errSecSuccess else {
            let found = (try? teamIdentifier(of: app)).flatMap { $0 }
            let reason = error?.takeRetainedValue().localizedDescription ?? "status \(status)"
            if status == errSecCSReqFailed {
                throw VMError("The update is not signed by the developer of this copy of Tandem.",
                              detail: "Expected team \(team); the update is signed by \(found.map { "team \($0)" } ?? "no developer (ad hoc)"). It is not installed.")
            }
            throw VMError("The update’s code signature is not valid.", detail: reason)
        }
    }

    // MARK: Install

    /// Swaps the staged app into place in one rename, then disposes of the old copy. Returns where the old
    /// copy went (the Trash), or nil when it was deleted.
    @discardableResult
    public static func install(_ staged: Staged, oldCopy: OldCopy = .trash) throws -> URL? {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: staged.folder) }
        guard renamex_np(staged.app.path, staged.target.path, UInt32(RENAME_SWAP)) == 0 else {
            let code = errno
            throw VMError("Tandem could not put the update in place.", detail: "\(staged.target.path): \(String(cString: strerror(code)))")
        }
        // staged.app is now the old copy.
        var trashed: URL?
        switch oldCopy {
        case .trash:
            var result: NSURL?
            if (try? fm.trashItem(at: staged.app, resultingItemURL: &result)) != nil { trashed = result as URL? }
            else { try? fm.removeItem(at: staged.app) }
        case .delete:
            try? fm.removeItem(at: staged.app)
        }
        return trashed
    }

    /// Removes staging folders an interrupted update left next to the app (called at launch, when no
    /// update can be under way).
    public static func removeLeftovers(nextTo app: URL) {
        let parent = app.standardizedFileURL.deletingLastPathComponent()
        let items = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in items where name.hasPrefix(".Tandem-update-") {
            try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
        }
    }

    /// Removes a staged update that will not be installed.
    public static func discard(_ staged: Staged) {
        try? FileManager.default.removeItem(at: staged.folder)
    }
}
