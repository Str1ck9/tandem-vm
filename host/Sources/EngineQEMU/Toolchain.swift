import Foundation
import VMCore

/// Locates QEMU, swtpm and the UEFI firmware: the copies a packaged Tandem.app carries
/// first (`BundledTools`), then this project's own QEMU build, then Homebrew.
public struct QEMUToolchain: Sendable, Equatable {
    public var qemu: URL
    public var qemuImg: URL
    public var swtpm: URL?
    public var firmwareCode: URL
    public var firmwareVarsTemplate: URL
    public var qemuVersion: String
    /// QEMU's data folder (option ROMs, keymaps) when it does not sit at `bin/../share/qemu`: a packaged
    /// Tandem.app keeps data out of `Contents/Helpers`, which may only hold code, in `Resources/qemu`.
    /// Passed to QEMU with `-L`. Nil: QEMU finds its own.
    public var dataDirectory: URL? = nil

    /// Version this project was tested against. Other versions produce a warning, not a failure.
    public static let testedQEMUMajor = 11

    public static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Environment variable naming the install prefix of this project's own QEMU build.
    public static let prefixVariable = "TANDEM_QEMU_PREFIX"

    /// Where `scripts/build-qemu.sh` installs by default.
    public static var defaultBuildPrefix: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tandem/qemu", isDirectory: true)
    }

    /// `bin` directories of this project's QEMU build, searched before Homebrew's. The build carries a patch
    /// that Windows 11 22H2 needs to boot under HVF (`patches/qemu-11.1.3-hvf-unknown-smc.patch`).
    public static func preferredDirectories(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var prefixes: [String] = []
        if let custom = environment[prefixVariable], !custom.isEmpty { prefixes.append(custom) }
        if let bundled = BundledTools.qemuPrefix(environment: environment) { prefixes.append(bundled.path) }
        prefixes.append(defaultBuildPrefix.path)
        return prefixes.map { URL(fileURLWithPath: $0).appendingPathComponent("bin").path }
    }

    /// True when QEMU comes from this project's patched build rather than a stock install.
    public var isPatchedBuild: Bool {
        Self.preferredDirectories().contains(qemu.deletingLastPathComponent().path)
    }

    public static func find(_ name: String, extraDirectories: [String] = []) -> URL? {
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in extraDirectories + searchDirectories + pathDirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public static func locate() throws -> QEMUToolchain {
        var missing: [String] = []
        let preferred = preferredDirectories()
        let qemu = find("qemu-system-aarch64", extraDirectories: preferred); if qemu == nil { missing.append("qemu-system-aarch64 (brew install qemu)") }
        let img = find("qemu-img", extraDirectories: preferred); if img == nil { missing.append("qemu-img (brew install qemu)") }
        guard let qemu, let img else {
            throw VMError("QEMU is not installed, so Windows and other QEMU-based VMs cannot start.",
                          detail: "Missing: " + missing.joined(separator: ", ") + "\nInstall it with: brew install qemu swtpm (or build Tandem's own copy with scripts/build-qemu.sh).")
        }
        // share/qemu sits next to bin/ in the real (symlink-resolved) install prefix; a packaged app keeps it
        // in Resources/qemu instead (BundledTools.qemuDataDirectory).
        let bundledData = BundledTools.qemuDataDirectory(forQEMU: qemu)
        let share = bundledData ?? qemu.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("share/qemu")
        let code = share.appendingPathComponent("edk2-aarch64-code.fd")
        let vars = share.appendingPathComponent("edk2-arm-vars.fd")
        for file in [code, vars] where !FileManager.default.fileExists(atPath: file.path) {
            throw VMError("UEFI firmware is missing from the QEMU install.", detail: file.path)
        }
        let version = (try? run(qemu, ["--version"]))?.split(separator: "\n").first.map(String.init) ?? "unknown"
        let swtpm = BundledTools.tool("swtpm") ?? find("swtpm")
        return QEMUToolchain(qemu: qemu, qemuImg: img, swtpm: swtpm, firmwareCode: code,
                             firmwareVarsTemplate: vars, qemuVersion: version, dataDirectory: bundledData)
    }

    // MARK: 3D build (experimental)

    /// Environment variable naming the prefix of a 3D-capable QEMU build (virtio-gpu-gl, SPICE with GL).
    public static let prefix3DVariable = "TANDEM_QEMU_3D_PREFIX"

    /// Where a 3D-capable QEMU is looked for, first match wins: the variable above, the copy a packaged
    /// Tandem.app carries (`Contents/Helpers/qemu-3d`), an installed `Tandem/qemu-3d`, then a staged
    /// `Tandem/qemu-3d.staged` (made by `scripts/build-qemu-3d.sh`).
    public static func prefixes3D(environment: [String: String] = ProcessInfo.processInfo.environment, windows: Bool = false,
                                  executable: URL? = Bundle.main.executableURL) -> [URL] {
        var prefixes: [URL] = []
        if let custom = environment[prefix3DVariable], !custom.isEmpty { prefixes.append(URL(fileURLWithPath: custom)) }
        if let bundled = BundledTools.qemu3DPrefix(environment: environment, executable: executable) { prefixes.append(bundled) }
        let support = defaultBuildPrefix.deletingLastPathComponent()
        prefixes.append(support.appendingPathComponent("qemu-3d", isDirectory: true))
        prefixes.append(support.appendingPathComponent("qemu-3d.staged", isDirectory: true))
        if windows {
            // Windows 3D needs DXMT and the render server next to virglrenderer (locate3D skips builds
            // without them). The main 3D build carries them and the shared-memory scanout patch that puts
            // the desktop in Tandem's window, so it comes first; an older separate build is the fallback
            // (measured: picked first, it left the window at "Display output is not active").
            prefixes.append(support.appendingPathComponent("qemu-3d-win", isDirectory: true))
            prefixes.append(support.appendingPathComponent("qemu-3d-win.staged", isDirectory: true))
        }
        return prefixes
    }

    /// The 3D-capable QEMU: same layout as the normal build (bin/, share/qemu) plus Frameworks/ with
    /// ANGLE, libepoxy and virglrenderer. swtpm and qemu-img are taken from the normal toolchain.
    /// DXMT inside a 3D prefix: Direct3D 11 on Metal, loaded by virglrenderer for the Windows driver.
    public static func dxmtLibrary(in prefix: URL) -> URL {
        prefix.appendingPathComponent("Frameworks/dxmt-native.framework/dxmt-native")
    }

    /// virglrenderer's render server inside a 3D prefix: the process where Direct3D (Neptune, DXMT) runs.
    public static func renderServer(in prefix: URL) -> URL {
        prefix.appendingPathComponent("libexec/virgl_render_server")
    }

    /// The prefix of a located QEMU binary (two levels above bin/qemu-system-aarch64).
    public static func prefix(of qemu: URL) -> URL { qemu.deletingLastPathComponent().deletingLastPathComponent() }

    public static func locate3D(environment: [String: String] = ProcessInfo.processInfo.environment, windows: Bool = false) throws -> QEMUToolchain {
        let base = try locate()
        for prefix in prefixes3D(environment: environment, windows: windows) {
            if windows && !(FileManager.default.fileExists(atPath: dxmtLibrary(in: prefix).path)
                            && FileManager.default.isExecutableFile(atPath: renderServer(in: prefix).path)) { continue }
            let qemu = prefix.appendingPathComponent("bin/qemu-system-aarch64")
            guard FileManager.default.isExecutableFile(atPath: qemu.path) else { continue }
            // A packaged app's 3D QEMU shares the app's firmware folder (Resources/qemu, passed with -L);
            // a staged build has its own share/qemu.
            let bundledData = BundledTools.qemuDataDirectory(forQEMU: qemu)
            let share = bundledData ?? prefix.appendingPathComponent("share/qemu")
            let code = share.appendingPathComponent("edk2-aarch64-code.fd")
            let vars = share.appendingPathComponent("edk2-arm-vars.fd")
            guard FileManager.default.fileExists(atPath: code.path), FileManager.default.fileExists(atPath: vars.path) else { continue }
            let version = (try? run(qemu, ["--version"]))?.split(separator: "\n").first.map(String.init) ?? "unknown"
            return QEMUToolchain(qemu: qemu, qemuImg: base.qemuImg, swtpm: base.swtpm, firmwareCode: code,
                                 firmwareVarsTemplate: vars, qemuVersion: version, dataDirectory: bundledData)
        }
        if windows {
            throw VMError("3D acceleration for Windows needs Tandem's 3D build of QEMU with DXMT, which is not installed.",
                          detail: "Build it with scripts/build-qemu-3d.sh (it builds DXMT from source too), or turn 3D acceleration off under Configure > Hardware > Graphics.")
        }
        throw VMError("3D acceleration needs Tandem's 3D build of QEMU, which is not installed.",
                      detail: "Build it with scripts/build-qemu-3d.sh, or turn 3D acceleration off under Configure > Hardware > Graphics.")
    }

    public var versionWarning: String? {
        guard let major = qemuVersion.split(separator: " ").compactMap({ Int($0.split(separator: ".").first ?? "") }).first else { return nil }
        return major == Self.testedQEMUMajor ? nil
            : "QEMU \(major) is installed; this build was tested with QEMU \(Self.testedQEMUMajor)."
    }

    /// Runs a tool and returns stdout. Throws with stderr if it exits non-zero, and stops the tool after
    /// `timeout` seconds (the default suits qemu-img create, resize and info; converting or comparing a
    /// whole disk passes `ToolRun.Limit.disk`).
    @discardableResult
    public static func run(_ tool: URL, _ arguments: [String], timeout: TimeInterval = ToolRun.Limit.image) throws -> String {
        let result = try ToolRun.run(tool, arguments, timeout: timeout)
        guard result.succeeded else {
            throw VMError("\(tool.lastPathComponent) failed (exit \(result.status)).", detail: result.errorText)
        }
        return result.outputText
    }
}
