import Foundation
import SystemConfiguration
import VMCore

/// Installs the network helper that bridged networking needs. The helper and its installer script
/// travel inside the app; macOS asks for the administrator password.
enum NetHelperInstaller {
    static func install() throws {
        // A packaged, signed Tandem installs its helper the macOS way (no password, approved once).
        if HelperService.isAvailable { try HelperService.register(); return }
        guard let resources = Bundle.main.resourceURL else { throw VMError("This copy of Tandem has no resources folder.") }
        let script = resources.appendingPathComponent("install-net-helper.sh")
        let inHelpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/TandemNetHelper")
        let binary = FileManager.default.isExecutableFile(atPath: inHelpers.path) ? inHelpers : resources.appendingPathComponent("TandemNetHelper")
        guard FileManager.default.fileExists(atPath: script.path), FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw VMError("This copy of Tandem does not include the network helper.", detail: "From the source folder, run: sudo scripts/install-net-helper.sh")
        }
        func shellQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        // The script names the helper after this build's identifiers (validated: letters, digits, . _ -).
        var command = "\(TandemIdentity.prefixEnvironmentVariable)=\(TandemIdentity.prefix) \(TandemIdentity.appEnvironmentVariable)=\(TandemIdentity.app) /bin/bash \(shellQuoted(script.path)) --uid \(getuid()) --binary \(shellQuoted(binary.path))"
        // USB devices: the usbredirect bundle the app carries (scripts/bundle-usbredirect.sh).
        let usbredirect = resources.appendingPathComponent("usbredirect")
        if FileManager.default.isExecutableFile(atPath: usbredirect.appendingPathComponent("usbredirect").path) {
            command += " --usbredirect \(shellQuoted(usbredirect.path))"
        }
        // USB drives: the qemu-nbd bundle the app carries (scripts/bundle-qemu-nbd.sh).
        let qemuNBD = resources.appendingPathComponent("qemu-nbd")
        if FileManager.default.isExecutableFile(atPath: qemuNBD.appendingPathComponent("qemu-nbd").path) {
            command += " --qemu-nbd \(shellQuoted(qemuNBD.path))"
        }
        func appleScriptQuoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let source = "do shell script \(appleScriptQuoted(command)) with prompt \(appleScriptQuoted("Tandem wants to install its helper, which bridged networking and USB devices need.")) with administrator privileges"
        // The limit leaves the user plenty of time for the password dialog.
        let result = try ToolRun.run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", source],
                                     timeout: ToolRun.Limit.userPrompt, output: .discard)
        let stderr = result.errorText
        guard result.succeeded else {
            // -128 is the user pressing Cancel in the password dialog.
            if stderr.contains("-128") { throw VMError("The network helper was not installed.", detail: "The password dialog was cancelled.") }
            throw VMError("The network helper could not be installed.", detail: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// "Wi-Fi (en0)" for `en0`, from the Mac's network settings; the bare name when it is not listed there.
    static func displayName(of interface: String) -> String {
        let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        for item in all where SCNetworkInterfaceGetBSDName(item) as String? == interface {
            if let name = SCNetworkInterfaceGetLocalizedDisplayName(item) as String? { return "\(name) (\(interface))" }
        }
        return interface
    }
}
