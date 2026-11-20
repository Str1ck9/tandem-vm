import Foundation
import VMCore

/// `qemu-img` operations used when importing existing disks.
public enum QEMUDiskTools {
    /// Creates a qcow2 overlay on `backing`. The backing image is only ever read, so the original VM is not changed.
    public static func createOverlay(toolchain: QEMUToolchain, at url: URL, backing: URL, backingFormat: String) throws -> DiskBacking {
        let fingerprint = try DiskBacking.fingerprint(path: backing.path, format: backingFormat)
        try QEMUToolchain.run(toolchain.qemuImg, ["create", "-q", "-f", "qcow2", "-b", backing.path, "-F", backingFormat, url.path])
        return fingerprint
    }

    /// Full, independent copy in another format. `-U` reads the source without taking a write lock.
    public static func convert(toolchain: QEMUToolchain, source: URL, sourceFormat: String, to url: URL, format: DiskFormat) throws {
        try QEMUToolchain.run(toolchain.qemuImg, ["convert", "-U", "-f", sourceFormat, "-O", format.rawValue, source.path, url.path],
                              timeout: ToolRun.Limit.disk)
    }
}

/// Writes a UEFI boot entry for an imported disk.
///
/// A hypervisor keeps boot entries in its own NVRAM file, which does not move with the disk. Windows installs a
/// fallback loader (`\EFI\BOOT\BOOTAA64.EFI`) so it boots anyway; most Linux installs do not, and the firmware
/// drops to its shell. This runs the VM once without a display, finds the loader from the firmware shell on the
/// serial port (read-only: the shell only lists the EFI partition), adds the entry with `bcfg`, and powers off. The entry lands in the bundle's `efi-vars.fd`.
public enum EFIBootFixer {
    public enum Outcome: Equatable, Sendable {
        /// The firmware booted the disk without help.
        case notNeeded
        case added(loader: String)
    }

    /// Loader file names, best first. The shim chain-loads GRUB and is what distributions register themselves.
    static let loaderNames = ["shimaa64.efi", "grubaa64.efi", "systemd-bootaa64.efi"]

    public static func run(bundle: VMBundle, toolchain: QEMUToolchain, timeout: TimeInterval = 120) throws -> Outcome {
        // This run writes the VM's firmware variables, so it holds the VM's lease like any run.
        let lease = try BundleLease.acquire(bundle, purpose: "having its boot entry repaired")
        defer { lease.release() }
        let paths = QEMURunPaths.forVM(bundle.id)
        try QEMUEngine.prepare(bundle: bundle, toolchain: toolchain, paths: paths)
        try QEMUEngine.prepareRunFolder(paths, lease: lease)
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        // Same devices as a normal run: the boot entry records the disk's PCI address, so it must not differ.
        var arguments = try QEMUCommandBuilder.arguments(bundle: bundle, toolchain: toolchain, paths: paths, display: .none)
        guard let serial = arguments.firstIndex(of: "-serial"), serial + 1 < arguments.count else {
            throw VMError("Internal error: the QEMU command has no serial port.")
        }
        arguments[serial + 1] = "stdio"

        let process = Process()
        process.executableURL = toolchain.qemu
        process.arguments = arguments
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.stopAndWait() }

        let console = SerialConsole(reader: stdout.fileHandleForReading, writer: stdin.fileHandleForWriting)
        let deadline = Date().addingTimeInterval(timeout)

        // Either the shell prompt appears, or a boot loader takes over (GRUB menu, kernel messages).
        let first = try console.wait(for: ["Shell>", "GNU GRUB", "Linux version", "EFI stub:"], until: deadline, process: process)
        guard first == "Shell>" else { return .notNeeded }

        var found: String? = nil
        search: for fs in 0..<6 {
            let listing = try console.command("ls fs\(fs):\\EFI", until: deadline, process: process)
            for directory in directoryNames(inListing: listing) where directory.uppercased() != "BOOT" {
                let files = try console.command("ls fs\(fs):\\EFI\\\(directory)", until: deadline, process: process).lowercased()
                if let loader = loaderNames.first(where: { files.contains($0) }) {
                    found = "fs\(fs):\\EFI\\\(directory)\\\(loader)"
                    break search
                }
            }
        }
        guard let loader = found else {
            throw VMError("No boot loader was found on “\(bundle.config.name)”.",
                          detail: "The firmware shell saw no \\EFI\\<name>\\{\(loaderNames.joined(separator: ","))} on any partition.")
        }
        let result = try console.command("bcfg boot add 0 \(loader) \"Imported OS\"", until: deadline, process: process)
        guard !result.lowercased().contains("error"), !result.lowercased().contains("not found") else {
            throw VMError("The firmware refused the boot entry for \(loader).", detail: result)
        }
        console.send("reset -s\r")
        let stop = Date().addingTimeInterval(10)
        while process.isRunning, Date() < stop { Thread.sleep(forTimeInterval: 0.1) }
        return .added(loader: loader)
    }

    /// Directory names from the output of the UEFI shell's `ls`, whose rows look like
    /// `10/13/2026  19:03 <DIR>         4,096  kali`.
    static func directoryNames(inListing listing: String) -> [String] {
        listing.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard let range = line.range(of: "<DIR>") else { return nil }
            let fields = line[range.upperBound...].split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { return nil }
            let name = fields.dropFirst().joined(separator: " ")
            return name == "." || name == ".." ? nil : name
        }
    }

    /// Strips terminal escape sequences from firmware console output.
    static func plainText(_ raw: String) -> String {
        // Colour changes sit inside a line (the shell colours file names); cursor moves act as line breaks.
        raw.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;=?]*[A-Za-z]", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Expect-style access to the firmware console on QEMU's stdio.
    final class SerialConsole {
        private let writer: FileHandle
        private var buffer = ""
        private let lock = NSLock()

        init(reader: FileHandle, writer: FileHandle) {
            self.writer = writer
            reader.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let self else { return }
                let text = String(decoding: data, as: UTF8.self)
                self.lock.withLock { self.buffer += text }
            }
        }

        func send(_ text: String) { try? writer.write(contentsOf: Data(text.utf8)) }

        /// Waits until one of `markers` appears in output not yet consumed; consumes through it and returns it.
        @discardableResult
        func wait(for markers: [String], until deadline: Date, process: Process) throws -> String {
            while true {
                let hit: (String, String)? = lock.withLock {
                    let plain = EFIBootFixer.plainText(buffer)
                    let hits = markers.compactMap { m in plain.range(of: m).map { (m, $0) } }
                    guard let (marker, range) = hits.min(by: { $0.1.lowerBound < $1.1.lowerBound }) else { return nil }
                    let before = String(plain[..<range.lowerBound])
                    buffer = String(plain[range.upperBound...])
                    return (marker, before)
                }
                if let hit { lastOutput = hit.1; return hit.0 }
                guard process.isRunning else { throw VMError("QEMU exited while fixing the boot entry.") }
                guard Date() < deadline else { throw VMError("Timed out waiting for the firmware (\(markers.joined(separator: ", "))).") }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        private(set) var lastOutput = ""

        /// Runs a shell command and returns what it printed before the next prompt.
        func command(_ line: String, until deadline: Date, process: Process) throws -> String {
            send(line + "\r")
            try wait(for: ["Shell>"], until: deadline, process: process)
            return lastOutput
        }
    }
}
