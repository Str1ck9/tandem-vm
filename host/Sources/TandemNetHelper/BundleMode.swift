import Foundation
import Security

// MARK: Running from inside Tandem.app
//
// When macOS's own service manager (SMAppService) starts the helper from inside Tandem.app, its launch
// file is part of the signed app and cannot name the user or where the app was put. `--from-bundle`
// derives both:
// - the user it serves is the owner of the app bundle (the person who copied Tandem.app into place);
//   if the bundle belongs to root (installed by a package), the user logged in at the console;
// - the tools it runs as root (qemu-nbd, usbredirect) are the ones inside the same app, and only if
//   they are signed by the same developer team as the helper itself. A bundle in /Applications is often
//   writable by its owner, so the signature, not the folder, is what makes them safe to run as root.

/// The `.app` folder an executable lives in, if any (`…/Tandem.app/Contents/Helpers/TandemNetHelper`).
func enclosingAppBundle(of executable: String) -> URL? {
    var url = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
    while url.path != "/" {
        if url.pathExtension == "app" { return url }
        url.deleteLastPathComponent()
    }
    return nil
}

/// The user an in-app helper serves: the app bundle's owner, else the console user. Nil if neither is a
/// normal user.
func bundleUser(appBundle: URL) -> uid_t? {
    var info = stat()
    if stat(appBundle.path, &info) == 0, info.st_uid != 0 { return info.st_uid }
    if stat("/dev/console", &info) == 0, info.st_uid != 0 { return info.st_uid }
    return nil
}

/// Where the app keeps the tools the helper runs (see scripts/package-app.sh).
func bundledHelperTools(appBundle: URL) -> (usbredirect: String, qemuNBD: String) {
    let helpers = appBundle.appendingPathComponent("Contents/Helpers")
    return (helpers.appendingPathComponent("tools/usbredirect").path,
            helpers.appendingPathComponent("qemu/bin/qemu-nbd").path)
}

/// The developer team that signed this running program; nil when it is signed ad hoc.
func ownTeamIdentifier() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any] else { return nil }
    return dict[kSecCodeInfoTeamIdentifier as String] as? String
}

/// True when the program at `path` carries a valid signature from `team` (a Developer ID or Apple
/// development certificate of that team). Checked before every run, so a program swapped after the
/// helper started is refused too.
/// The identifier is pinned too (`<bundle prefix>.<file name>`), so another program of the same team (QEMU,
/// the command-line tool) cannot be put in a tool's place. This check gives an early, clear answer; the
/// one that counts is made on the started process (ToolProcess.swift), because the file can change in between.
func signedByTeam(_ path: String, team: String) -> Bool {
    guard let text = toolRequirement(identifier: expectedIdentifier(forTool: path), team: team) else { return false }
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
          let staticCode else { return false }
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
    let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    return SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess
}

/// Whether root may run `path`: in bundle mode it must be signed by the helper's own team; otherwise
/// (installed by scripts/install-net-helper.sh) it must be owned by root and not writable by others, as
/// the installer leaves it.
func mayRunAsRoot(_ path: String, requiredTeam: String?) -> Bool {
    if let requiredTeam { return signedByTeam(path, team: requiredTeam) }
    var info = stat()
    guard stat(path, &info) == 0 else { return false }
    return info.st_uid == 0 && (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
}
