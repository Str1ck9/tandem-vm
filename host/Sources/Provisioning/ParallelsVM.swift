import Foundation
import VMCore

/// Reads an existing Parallels Desktop VM bundle (`.pvm` or `.macvm`) so it can be imported.
/// Only the on-disk XML is parsed; nothing in the bundle is written.
public struct ParallelsVM: Equatable, Sendable {
    public enum Kind: String, Sendable { case pvm, macvm }

    public struct Disk: Equatable, Sendable {
        /// The `.hdd` directory.
        public var directory: URL
        /// Image files listed in `DiskDescriptor.xml`. More than one means snapshots or a split disk.
        public var images: [URL]
        /// `Compressed` (Parallels expanding format) or `Plain` (raw).
        public var imageType: String
        public var sizeBytes: UInt64
        public var snapshotCount: Int
        public var encrypted: Bool

        /// QEMU block driver for the image.
        public var qemuFormat: String { imageType == "Plain" ? "raw" : "parallels" }
    }

    public var url: URL
    public var kind: Kind
    public var name: String
    public var guestOS: GuestOS?
    public var cpuCount: Int
    public var memoryMiB: Int
    public var mac: String?
    /// `SourceVmUuid`: the identity Parallels keeps when a VM is moved and replaces when it is copied.
    /// It is the firmware (SMBIOS) UUID the guest saw: a Windows guest's hardware history
    /// (HKLM\SYSTEM\HardwareConfig) lists it under Parallels' name, in the same byte order QEMU uses.
    public var sourceUUID: UUID? = nil
    /// The description the user gave the VM.
    public var notes: String? = nil
    /// The colour the user gave the VM in the list, as `#RRGGBB`.
    public var color: String? = nil
    public var hasTPM: Bool
    public var disks: [Disk]
    public var suspended: Bool

    /// Reasons the VM cannot be imported as it is. Empty means importable.
    public var blockers: [String] {
        var out: [String] = []
        if guestOS == nil { out.append("The guest operating system is not one this app runs (ARM64 Windows 11, Linux or macOS).") }
        if disks.isEmpty { out.append("The VM has no hard disk.") }
        if disks.count > 1 { out.append("The VM has \(disks.count) hard disks; only single-disk VMs can be imported so far.") }
        for d in disks {
            let name = d.directory.lastPathComponent
            if d.encrypted { out.append("\(name) is encrypted. Remove the encryption in Parallels first.") }
            if d.snapshotCount > 1 || d.images.count > 1 {
                out.append("\(name) has snapshots. Delete them in Parallels first (this merges them into the disk).")
            }
            for image in d.images where !FileManager.default.fileExists(atPath: image.path) {
                out.append("Disk image is missing: \(image.path)")
            }
        }
        if suspended { out.append("The VM is suspended. Resume it in Parallels and shut it down first.") }
        return out
    }

    public static func inspect(_ url: URL) throws -> ParallelsVM {
        let url = url.standardizedFileURL
        guard let kind = Kind(rawValue: url.pathExtension.lowercased()) else {
            throw VMError("\(url.lastPathComponent) is not a Parallels VM (.pvm or .macvm).")
        }
        let configURL = url.appendingPathComponent("config.pvs")
        let config: XMLDocument
        do { config = try XMLDocument(contentsOf: configURL) }
        catch { throw VMError("Cannot read \(configURL.path).", detail: error.localizedDescription) }

        func text(_ xpath: String) -> String? {
            ((try? config.nodes(forXPath: xpath))?.first?.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let osType = Int(text("/ParallelsVirtualMachine/Settings/General/OsType") ?? "") ?? -1
        let hardware = "/ParallelsVirtualMachine/Hardware"

        var disks: [Disk] = []
        for node in (try? config.nodes(forXPath: "\(hardware)/Hdd")) ?? [] {
            func field(_ name: String) -> String? {
                (try? node.nodes(forXPath: name))?.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard field("Enabled") != "0", field("Connected") != "0", let system = field("SystemName"), !system.isEmpty else { continue }
            let directory = system.hasPrefix("/") ? URL(fileURLWithPath: system) : url.appendingPathComponent(system)
            disks.append(try disk(at: directory))
        }

        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        let suspended = entries.contains { $0.hasSuffix(".sav") || $0.hasSuffix(".mem") }

        return ParallelsVM(
            url: url, kind: kind,
            name: text("/ParallelsVirtualMachine/Identification/VmName") ?? url.deletingPathExtension().lastPathComponent,
            guestOS: guestOS(kind: kind, osType: osType),
            cpuCount: Int(text("\(hardware)/Cpu/Number") ?? "") ?? 2,
            memoryMiB: Int(text("\(hardware)/Memory/RAM") ?? "") ?? 4096,
            mac: text("\(hardware)/NetworkAdapter/MAC").flatMap(formatMAC),
            sourceUUID: text("/ParallelsVirtualMachine/Identification/SourceVmUuid")
                .flatMap { UUID(uuidString: $0.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))) },
            notes: text("/ParallelsVirtualMachine/Settings/General/VmDescription").flatMap { $0.isEmpty ? nil : $0 },
            color: text("/ParallelsVirtualMachine/Settings/General/VmColor").flatMap { Int($0) }
                .flatMap { $0 > 0 && $0 <= 0xFFFFFF ? String(format: "#%06X", $0) : nil },
            hasTPM: (Int(text("\(hardware)/TpmChip/Type") ?? "") ?? 0) != 0,
            disks: disks, suspended: suspended)
    }

    /// Parallels `OsType` values seen in config.pvs: 7 macOS, 8 Windows, 9 Linux.
    static func guestOS(kind: Kind, osType: Int) -> GuestOS? {
        if kind == .macvm { return .macos }
        switch osType {
        case 8: return .windows11arm
        case 9: return .linux
        default: return nil
        }
    }

    static func disk(at directory: URL) throws -> Disk {
        let descriptorURL = directory.appendingPathComponent("DiskDescriptor.xml")
        let doc: XMLDocument
        do { doc = try XMLDocument(contentsOf: descriptorURL) }
        catch { throw VMError("Cannot read \(descriptorURL.path).", detail: error.localizedDescription) }
        func all(_ xpath: String) -> [String] {
            ((try? doc.nodes(forXPath: xpath)) ?? []).compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        let sectors = UInt64(all("/Parallels_disk_image/Disk_Parameters/Disk_size").first ?? "") ?? 0
        let sectorSize = UInt64(all("/Parallels_disk_image/Disk_Parameters/LogicSectorSize").first ?? "") ?? 512
        let engine = all("/Parallels_disk_image/Disk_Parameters/Encryption/Engine").first ?? ""
        let noEngine = engine.isEmpty || engine.allSatisfy { "{}-0".contains($0) }
        return Disk(
            directory: directory,
            images: all("/Parallels_disk_image/StorageData/Storage/Image/File").map {
                $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : directory.appendingPathComponent($0)
            },
            imageType: all("/Parallels_disk_image/StorageData/Storage/Image/Type").first ?? "Compressed",
            sizeBytes: sectors * sectorSize,
            snapshotCount: all("/Parallels_disk_image/Snapshots/Shot/GUID").count,
            encrypted: !noEngine)
    }

    /// `001C42A00C16` → `00:1c:42:a0:0c:16`. Nil when the value is not 12 hex digits.
    static func formatMAC(_ raw: String) -> String? {
        let hex = raw.lowercased().filter { $0.isHexDigit }
        guard hex.count == 12 else { return nil }
        return stride(from: 0, to: 12, by: 2).map { i -> String in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[start..<hex.index(start, offsetBy: 2)])
        }.joined(separator: ":")
    }

    /// The config a VM imported from this bundle starts with. Disks are filled in by the importer.
    public func proposedConfig(name: String? = nil) throws -> VMConfig {
        guard let os = guestOS else { throw VMError("“\(self.name)” cannot be imported.", detail: blockers.joined(separator: "\n")) }
        let hostCPUs = ProcessInfo.processInfo.processorCount
        let hostMiB = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
        // Linux goes to QEMU too: its Parallels disk can be used in place there, and VZ needs a raw copy.
        let engine: EngineKind = os == .macos ? .vz : .qemu
        var config = VMConfig(name: name ?? self.name, guestOS: os, engine: engine,
                              cpuCount: min(max(cpuCount, 1), hostCPUs), memoryMiB: min(max(memoryMiB, 1024), hostMiB),
                              tpm: os == .windows11arm)
        if let mac { config.network.mac = mac }
        config.hardwareUUID = sourceUUID
        config.notes = notes
        config.color = color
        config.install = InstallInfo(state: .complete)
        return config
    }
}
