import Foundation
import VMCore

/// The Windows 3D display driver Tandem installs for "3D acceleration (Windows, experimental)".
///
/// The driver is `viogpu3d` from UTM's guest tools: open source (virtio-win, BSD-style licence) and signed by
/// Microsoft through attestation, so Windows installs it without test mode. Tandem downloads one pinned
/// release of the guest tools disc from UTM's official release page, checks it against the hash below, and
/// copies only the ARM64 driver files (plus the licence) onto a small disc for the VM.
public enum Windows3DDriver {
    public static let version = "0.1.274"
    public static let release = DownloadRequest(
        url: URL(string: "https://github.com/utmapp/qemu/releases/download/v10.0.12-utm/utm-guest-tools-0.1.274.iso")!,
        fileName: "utm-guest-tools-0.1.274.iso",
        checksum: .sha256("ab6add47a4ed992f5920f14e96f68d60566e6f731e2cf816c3d38ab2b78f407a"),
        expectedBytes: 143_898_624)

    /// Where the driver files sit on the guest tools disc.
    static let driverFolder = "Drivers/viogpu3d/w11/ARM64"
    static let licenceFile = "virtio-win_license.txt"
    /// The files that make up the driver; all must be present.
    static let requiredFiles = ["viogpu3d.inf", "viogpu3d.cat", "viogpu3d.sys"]
    public static let discFileName = "viogpu3d-driver.iso"
    static let discLabel = "TANDEM3D"

    /// Makes sure the driver disc exists in the bundle folder, downloading the guest tools release once into
    /// `cache`. Attaching it to the VM is the caller's job (`RemovableMedia(file: discFileName, kind: .driverDisc)`).
    public static func ensureDisc(in bundleFolder: URL, cache: URL,
                                  progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) async throws {
        let disc = bundleFolder.appendingPathComponent(discFileName)
        if FileManager.default.fileExists(atPath: disc.path) { return }
        let iso = try await Downloader(cache: cache).fetch(release, progress: progress)
        try buildDisc(from: iso, to: disc)
    }

    public static func discExists(in bundleFolder: URL) -> Bool {
        FileManager.default.fileExists(atPath: bundleFolder.appendingPathComponent(discFileName).path)
    }

    /// Copies the ARM64 driver files and the licence out of the guest tools disc into a new small disc.
    static func buildDisc(from iso: URL, to disc: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("tandem-3d-driver-\(UUID().uuidString)")
        let mount = work.appendingPathComponent("mount")
        let stage = work.appendingPathComponent("stage")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try hdiutil(["attach", "-readonly", "-nobrowse", "-noverify", "-mountpoint", mount.path, iso.path])
        defer { _ = try? hdiutil(["detach", mount.path, "-force"]) }
        let source = mount.appendingPathComponent(driverFolder)
        let names = (try? fm.contentsOfDirectory(atPath: source.path)) ?? []
        for required in requiredFiles where !names.contains(required) {
            throw VMError("The 3D driver package is incomplete.", detail: "\(required) is missing from \(driverFolder) on \(iso.lastPathComponent).")
        }
        for name in names { try fm.copyItem(at: source.appendingPathComponent(name), to: stage.appendingPathComponent(name)) }
        let licence = mount.appendingPathComponent(licenceFile)
        if fm.fileExists(atPath: licence.path) { try fm.copyItem(at: licence, to: stage.appendingPathComponent(licenceFile)) }
        let partial = disc.deletingLastPathComponent().appendingPathComponent(".\(discFileName).partial.iso")
        try? fm.removeItem(at: partial)
        try hdiutil(["makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", discLabel, "-o", partial.path, stage.path])
        try? fm.removeItem(at: disc)
        try fm.moveItem(at: partial, to: disc)
    }

    @discardableResult
    static func hdiutil(_ arguments: [String]) throws -> String {
        // Through ToolRun: reading the pipe to its end first would wait for good on a wedged hdiutil.
        let result = try ToolRun.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments, timeout: ToolRun.Limit.image)
        guard result.succeeded else { throw ToolRun.failed(result, "The 3D driver disc could not be made.") }
        return result.outputText
    }

    // MARK: In the guest

    /// Run elevated in the guest: finds the driver disc by its INF file and installs the driver.
    /// Exits with pnputil's code (0 done, 3010 restart wanted), or 2 when no disc is found.
    public static let installScript = """
    $disc = Get-PSDrive -PSProvider FileSystem | Where-Object { Test-Path (Join-Path $_.Root 'viogpu3d.inf') } | Select-Object -First 1
    if (-not $disc) { Write-Output 'no driver disc'; exit 2 }
    $inf = Join-Path $disc.Root 'viogpu3d.inf'
    & pnputil.exe /add-driver $inf /install
    exit $LASTEXITCODE
    """

    /// A PowerShell command line for a script, encoded so no shell quoting can break it.
    public static func powerShell(_ script: String) -> String {
        var data = Data()
        for unit in script.utf16 { data.append(UInt8(unit & 0xFF)); data.append(UInt8(unit >> 8)) }
        return "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand \(data.base64EncodedString())"
    }

    public static var installCommand: String { powerShell(installScript) }

    /// Run elevated in the guest to take the driver out again.
    public static func removeCommand(publishedName: String) -> String {
        "pnputil /delete-driver \(publishedName) /uninstall /force"
    }

    public enum InstallOutcome: Equatable, Sendable {
        case installed(publishedName: String?, restartNeeded: Bool)
        case failed(String)
    }

    /// Reads `pnputil /add-driver` output. Exit 0 or 3010 (restart needed) is success; 2 means no disc was found.
    public static func outcome(exitCode: Int32, output: String) -> InstallOutcome {
        let published = output.split(whereSeparator: \.isNewline).lazy
            .compactMap { line -> String? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].lowercased().contains("published name") else { return nil }
                return parts[1].trimmingCharacters(in: .whitespaces)
            }.first
        switch exitCode {
        case 0: return .installed(publishedName: published, restartNeeded: output.lowercased().contains("reboot") || output.lowercased().contains("restart"))
        case 3010: return .installed(publishedName: published, restartNeeded: true)
        case 2 where output.contains("no driver disc"):
            return .failed("Windows could not find the 3D driver disc.")
        default:
            let last = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            return .failed("pnputil ended with code \(exitCode)\(last.isEmpty ? "" : ": \(last)")")
        }
    }
}
