import Foundation

/// The programs a packaged Tandem.app carries (scripts/package-app.sh), so it needs neither Homebrew nor
/// files outside the app:
///
///     Tandem.app/Contents/Helpers/qemu/bin/{qemu-system-aarch64,qemu-img,qemu-nbd}
///     Tandem.app/Contents/Resources/qemu/…            firmware, ROMs and keymaps (passed with -L)
///     Tandem.app/Contents/Helpers/qemu/lib/*.dylib
///     Tandem.app/Contents/Helpers/tools/{swtpm,zstd,wimlib-imagex,usbredirect}, tools/lib/*.dylib
///
/// Every locator asks here first and falls back to where the tools were found before (Tandem's own QEMU
/// build in Application Support, then Homebrew), so a development build keeps working without packaging.
public enum BundledTools {
    /// Overrides the Helpers folder (tests, or running a packaged layout from elsewhere).
    public static let directoryVariable = "TANDEM_BUNDLED_TOOLS"

    /// `Contents/Helpers` of the app this program belongs to: the app itself, or the `tandem` tool and
    /// helper that live inside it. Nil for programs outside an app (vmctl in a build folder).
    public static func helpersDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                                        executable: URL? = Bundle.main.executableURL) -> URL? {
        if let custom = environment[directoryVariable], !custom.isEmpty { return URL(fileURLWithPath: custom, isDirectory: true) }
        guard let executable else { return nil }
        var url = executable.resolvingSymlinksInPath()
        while url.path != "/" {
            if url.pathExtension == "app" { return url.appendingPathComponent("Contents/Helpers", isDirectory: true) }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// The QEMU install prefix inside the app (it has `bin/` and `share/qemu`), if the app carries one.
    public static func qemuPrefix(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  executable: URL? = Bundle.main.executableURL) -> URL? {
        guard let prefix = helpersDirectory(environment: environment, executable: executable)?.appendingPathComponent("qemu", isDirectory: true),
              FileManager.default.isExecutableFile(atPath: prefix.appendingPathComponent("bin/qemu-system-aarch64").path) else { return nil }
        return prefix
    }

    /// The 3D-capable QEMU inside the app (`Contents/Helpers/qemu-3d`: bin/, lib/, Frameworks/ with ANGLE,
    /// libepoxy, virglrenderer, the Vulkan loader and DXMT, libexec/virgl_render_server), if the app carries one.
    public static func qemu3DPrefix(environment: [String: String] = ProcessInfo.processInfo.environment,
                                    executable: URL? = Bundle.main.executableURL) -> URL? {
        guard let prefix = helpersDirectory(environment: environment, executable: executable)?.appendingPathComponent("qemu-3d", isDirectory: true),
              FileManager.default.isExecutableFile(atPath: prefix.appendingPathComponent("bin/qemu-system-aarch64").path) else { return nil }
        return prefix
    }

    /// QEMU's data folder in a packaged app (`Contents/Resources/qemu`), for a QEMU that lives in the same
    /// app's `Contents/Helpers/<qemu or qemu-3d>/bin`; both share it. Nil for any other QEMU.
    public static func qemuDataDirectory(forQEMU qemu: URL) -> URL? {
        let bin = qemu.resolvingSymlinksInPath().deletingLastPathComponent()
        let helpers = bin.deletingLastPathComponent().deletingLastPathComponent()
        guard bin.lastPathComponent == "bin", helpers.lastPathComponent == "Helpers" else { return nil }
        let data = helpers.deletingLastPathComponent().appendingPathComponent("Resources/qemu", isDirectory: true)
        return FileManager.default.fileExists(atPath: data.appendingPathComponent("edk2-aarch64-code.fd").path) ? data : nil
    }

    /// A tool the app carries in `Helpers/tools` (or QEMU's own tools in `Helpers/qemu/bin`).
    public static func tool(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                            executable: URL? = Bundle.main.executableURL) -> URL? {
        guard let helpers = helpersDirectory(environment: environment, executable: executable) else { return nil }
        for folder in ["tools", "qemu/bin"] {
            let candidate = helpers.appendingPathComponent(folder).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// The bundled tool, else the first executable at one of `fallbacks`.
    public static func locate(_ name: String, fallbacks: [String],
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              executable: URL? = Bundle.main.executableURL) -> URL? {
        if let bundled = tool(name, environment: environment, executable: executable) { return bundled }
        return fallbacks.lazy.map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Where Homebrew and /usr/local keep a tool, as fallbacks for `locate`.
    public static func systemPaths(_ name: String) -> [String] {
        ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
    }
}
