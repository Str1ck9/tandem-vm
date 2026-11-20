import Foundation
import VMCore

/// Runs the Windows import repair (`Provisioning.WindowsImportRepair`): boots a Windows installer ISO with the
/// imported disk and the repair disk attached, and waits for the repair script to power the VM off.
public enum WindowsImportFixer {
    public static func run(bundle: VMBundle, toolchain: QEMUToolchain, windowsISO: URL, repairMedia: URL,
                           timeout: TimeInterval = 900) async throws {
        guard bundle.config.guestOS == .windows11arm else { throw VMError("“\(bundle.config.name)” is not a Windows VM.") }
        for file in [windowsISO, repairMedia] where !FileManager.default.fileExists(atPath: file.path) {
            throw VMError("File is missing: \(file.path)")
        }
        var work = bundle
        work.config.tpm = false // Setup's command environment does not need it, and it would need swtpm running.
        // The installer has no virtio display driver. Without a framebuffer it can draw on, Setup never gets as
        // far as running the script, so this run always uses the firmware framebuffer.
        work.config.display.virtioGPU = nil
        // The repair rewrites the default boot order below, so it must start from that order.
        work.config.boot = nil
        work.config.removableMedia = [RemovableMedia(file: windowsISO.path, kind: .installerISO),
                                      RemovableMedia(file: repairMedia.path, kind: .unattendDisk)]
        // This run writes the VM's disk, so it holds the VM's lease like any run.
        let lease = try BundleLease.acquire(bundle, purpose: "having Windows repaired")
        defer { lease.release() }
        // A different run directory, so this never collides with the VM's own sockets.
        let paths = QEMURunPaths(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tandem-fix-\(RunFolder.base32(bundle.id))", isDirectory: true))
        try QEMUEngine.prepare(bundle: work, toolchain: toolchain, paths: paths)
        try QEMUEngine.prepareRunFolder(paths, lease: lease)
        defer { try? FileManager.default.removeItem(at: paths.directory) }

        var arguments = try QEMUCommandBuilder.arguments(bundle: work, toolchain: toolchain, paths: paths, display: .none)
        // The installer must boot before the disk, which is the reverse of a normal run.
        arguments = arguments.map { argument in
            if argument.hasPrefix("nvme,drive=disk0") || argument.hasPrefix("virtio-blk-pci,drive=disk0") {
                return argument.replacingOccurrences(of: "bootindex=0", with: "bootindex=9")
            }
            if argument.hasPrefix("usb-storage,") && argument.contains("drive=media0") {
                return argument.replacingOccurrences(of: "bootindex=\(work.config.disks.count)", with: "bootindex=0")
            }
            return argument
        }
        if let serial = arguments.firstIndex(of: "-serial"), serial + 1 < arguments.count {
            arguments[serial + 1] = "file:\(bundle.logsDirectory.appendingPathComponent("repair-console.log").path)"
        }

        let process = Process()
        process.executableURL = toolchain.qemu
        process.arguments = arguments
        let logURL = bundle.logsDirectory.appendingPathComponent("repair-qemu.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        process.standardOutput = log; process.standardError = log
        try process.run()
        defer { process.stopAndWait() }

        // The installer waits five seconds for “Press any key to boot from CD or DVD”.
        let qmp = try await QMPClient.connect(path: paths.qmp, timeout: 15)
        defer { qmp.close() }
        for _ in 0..<12 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            guard process.isRunning else { break }
            _ = try? await qmp.execute("send-key", arguments: ["keys": [["type": "qcode", "data": "ret"]]])
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            guard Date() < deadline else {
                throw VMError("The Windows repair did not finish within \(Int(timeout / 60)) minutes.",
                              detail: "The script powers the VM off only when every change succeeded. If Windows Setup is "
                                + "showing instead, the repair failed; C:\\tandem-import.log inside the VM has the details.")
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard process.terminationStatus == 0 else {
            let tail = (try? String(contentsOf: logURL, encoding: .utf8))?.suffix(600) ?? ""
            throw VMError("QEMU failed during the Windows repair (exit \(process.terminationStatus)).", detail: String(tail))
        }
    }
}
