import Foundation
import VMCore
import Provisioning
import EngineQEMU

/// Imports an existing Parallels VM into the library. Used by both the app and `vmctl`.
/// Nothing in the Parallels bundle is ever written.
public enum ParallelsImporter {
    public struct Options: Sendable {
        public var name: String?
        /// Make a full, independent copy of the disk instead of an overlay (`.pvm`) or clone (`.macvm`).
        public var copy: Bool
        /// Windows 11 ARM64 installer ISO. Needed to make a Windows guest bootable.
        public var windowsISO: URL?
        /// virtio-win driver ISO. Adds network, display and guest-channel drivers to a Windows guest.
        public var virtioISO: URL?
        /// Windows build of the guest agent, installed into a Windows guest. Defaults to `defaultWindowsAgent`.
        public var windowsAgent: URL?

        public init(name: String? = nil, copy: Bool = false, windowsISO: URL? = nil, virtioISO: URL? = nil, windowsAgent: URL? = ParallelsImporter.defaultWindowsAgent) {
            self.name = name; self.copy = copy; self.windowsISO = windowsISO; self.virtioISO = virtioISO; self.windowsAgent = windowsAgent
        }
    }

    /// The Windows guest agent shipped with the app: inside the app bundle, or in Application Support.
    public static var defaultWindowsAgent: URL? { GuestTools.windowsAgent }

    public struct Result: Sendable {
        public var bundle: VMBundle
        /// Things the user should know afterwards, in plain sentences.
        public var notes: [String]
    }

    /// True while a Parallels VM process is running. Importing then could read a disk mid-write.
    public static func parallelsVMIsRunning() -> Bool {
        ["prl_vm_app", "prl_macvm_app"].contains { name in
            let result = try? ToolRun.run(URL(fileURLWithPath: "/usr/bin/pgrep"), ["-x", name], timeout: ToolRun.Limit.quick,
                                          output: .discard, errors: .discard)
            return result?.succeeded == true
        }
    }

    /// Runs the import. Blocks for seconds to minutes: call it off the main thread.
    public static func run(_ vm: ParallelsVM, options: Options, library: VMLibrary,
                           progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Result {
        guard vm.blockers.isEmpty, let source = vm.disks.first, let image = source.images.first else {
            throw VMError("“\(vm.name)” cannot be imported as it is.", detail: vm.blockers.joined(separator: "\n"))
        }
        guard !parallelsVMIsRunning() else {
            throw VMError("A Parallels VM is running.", detail: "Shut down all Parallels VMs before importing, so no disk is read while it is being written.")
        }
        var config = try vm.proposedConfig(name: options.name)
        let sizeGiB = max(1, Int((source.sizeBytes + (1 << 30) - 1) >> 30))
        let fileBytes = ((try? FileManager.default.attributesOfItem(atPath: image.path))?[.size] as? UInt64) ?? 0
        if options.copy {
            // Measured where the new VM goes: the VMs folder can be on another disk than the library's settings.
            try FreeSpace.require(Int64(fileBytes) + (5 << 30), at: library.vmsDirectory, for: "A full copy")
        }
        var notes: [String] = []

        switch config.guestOS {
        case .macos:
            config.disks = [DiskConfig(file: "disk0.img", sizeGiB: sizeGiB, bus: .virtio, format: .raw)]
            // Create the bundle without letting it make an empty disk, then bring the real files in.
            let bundle = try library.create(config, createDisks: false)
            do {
                let target = bundle.diskURL(config.disks[0])
                if options.copy {
                    progress("Copying the disk…")
                    try FileManager.default.copyItem(at: image, to: target)
                    notes.append("The disk was copied in full.")
                } else {
                    progress("Cloning the disk…")
                    guard clonefile(image.path, target.path, 0) == 0 else {
                        throw VMError("The disk cannot be cloned without copying (\(String(cString: strerror(errno)))).",
                                      detail: "The library must be on the same APFS volume as the Parallels VM. Choose a full copy instead.")
                    }
                    notes.append("The disk is an APFS clone: it uses no extra space now and is independent of the original.")
                }
                for (from, to) in [("aux.bin", bundle.auxiliaryStorageURL), ("machw.bin", bundle.hardwareModelURL), ("macid.bin", bundle.machineIdentifierURL)] {
                    try FileManager.default.copyItem(at: vm.url.appendingPathComponent(from), to: to)
                }
            } catch { try? library.delete(bundle); throw error }
            return Result(bundle: bundle, notes: notes)

        case .linux, .windows11arm:
            let toolchain = try QEMUToolchain.locate()
            config.disks = [DiskConfig(file: "disk0.qcow2", sizeGiB: sizeGiB, bus: config.guestOS == .windows11arm ? .nvme : .virtio, format: .qcow2)]
            var bundle = try library.create(config)
            do {
                let target = bundle.diskURL(config.disks[0])
                if options.copy {
                    progress("Converting the disk (this reads the whole image)…")
                    try QEMUDiskTools.convert(toolchain: toolchain, source: image, sourceFormat: source.qemuFormat, to: target, format: .qcow2)
                    notes.append("The disk was copied in full.")
                } else {
                    progress("Linking to the original disk…")
                    bundle.config.disks[0].backing = try QEMUDiskTools.createOverlay(toolchain: toolchain, at: target, backing: image, backingFormat: source.qemuFormat)
                    try bundle.save()
                    notes.append("Changes are stored in this VM; the Parallels disk is only read. Do not start the VM in Parallels again: if its disk changes, this VM refuses to start.")
                }
                if config.guestOS == .linux {
                    progress("Adding the boot entry…")
                    if case .added(let loader) = try EFIBootFixer.run(bundle: bundle, toolchain: toolchain) {
                        notes.append("A boot entry was added for \(loader).")
                    }
                } else if let iso = options.windowsISO {
                    bundle = try await repairWindows(bundle, windowsISO: iso, virtioISO: options.virtioISO, agent: options.windowsAgent, progress: progress)
                    if options.windowsAgent != nil && options.virtioISO != nil { notes.append("The guest agent was installed and starts when you sign in to Windows.") }
                    notes.append("Windows was prepared for this hardware: its NVMe driver is enabled and the Parallels drivers are disabled.")
                    if options.virtioISO == nil { notes.append("No driver disc was given, so Windows has no network and a small fixed screen.") }
                    notes.append("Windows may ask to be activated again, because its virtual hardware changed.")
                    if !toolchain.isPatchedBuild {
                        notes.append("Windows 11 22H2 hangs at start on stock QEMU. Run scripts/build-qemu.sh once to install the patched build.")
                    }
                } else {
                    notes.append("This Windows VM will not start yet. Run the Windows repair with a Windows 11 ARM64 installer ISO.")
                }
            } catch { try? library.delete(bundle); throw error }
            return Result(bundle: bundle, notes: notes)
        }
    }

    /// Makes an imported Windows VM bootable (see `WindowsImportRepair`). Returns the bundle with its updated config.
    public static func repairWindows(_ bundle: VMBundle, windowsISO: URL, virtioISO: URL?, agent: URL? = ParallelsImporter.defaultWindowsAgent,
                                     progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> VMBundle {
        let toolchain = try QEMUToolchain.locate()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var drivers: URL? = nil
        if let virtioISO {
            progress("Collecting Windows drivers…")
            let directory = scratch.appendingPathComponent("drivers")
            _ = try VirtioDrivers.collect(fromISO: virtioISO, to: directory)
            drivers = directory
        }
        let media = scratch.appendingPathComponent("repair.iso")
        try WindowsImportRepair.buildMedia(at: media, driversDirectory: drivers, agentExecutable: agent)
        progress("Preparing Windows for this hardware…")
        try await WindowsImportFixer.run(bundle: bundle, toolchain: toolchain, windowsISO: windowsISO, repairMedia: media)
        var updated = bundle
        if drivers != nil {
            updated.config.display.virtioGPU = true
            try updated.save()
        }
        return updated
    }
}
