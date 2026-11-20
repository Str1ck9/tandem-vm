import Foundation

/// Guest operating system family. Selects the default engine.
public enum GuestOS: String, Codable, CaseIterable, Sendable {
    case windows11arm, linux, macos

    public var defaultEngine: EngineKind {
        switch self {
        case .windows11arm: return .qemu
        case .linux, .macos: return .vz
        }
    }
}

public enum EngineKind: String, Codable, CaseIterable, Sendable {
    case vz, qemu
}

public enum DiskBus: String, Codable, Sendable {
    case virtio, nvme
}

public enum DiskFormat: String, Codable, Sendable {
    case raw, qcow2
}

/// A read-only image that a qcow2 disk is layered on (used when importing a VM without copying its disk).
/// The size and modification time are recorded so a changed backing file is caught before it corrupts the overlay.
public struct DiskBacking: Codable, Equatable, Sendable {
    public var path: String
    /// QEMU block driver name of the backing image, for example `parallels`.
    public var format: String
    public var sizeBytes: UInt64
    public var modified: Date

    public init(path: String, format: String, sizeBytes: UInt64, modified: Date) {
        self.path = path; self.format = format; self.sizeBytes = sizeBytes; self.modified = modified
    }

    public static func fingerprint(path: String, format: String) throws -> DiskBacking {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        guard let size = attrs[.size] as? UInt64, let date = attrs[.modificationDate] as? Date else {
            throw VMError("Cannot read attributes of \(path).")
        }
        // Whole seconds, so the value survives a JSON round trip unchanged.
        return DiskBacking(path: path, format: format, sizeBytes: size,
                           modified: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)))
    }

    /// Nil when the backing file is unchanged, otherwise the reason it cannot be used.
    public func problem() -> String? {
        guard let now = try? Self.fingerprint(path: path, format: format) else {
            return "The original disk this VM is built on is missing: \(path)\nPut it back where it was (for example from your backup), then start the VM again."
        }
        if now.sizeBytes != sizeBytes || now.modified != modified {
            return "The original disk this VM is built on has changed since it was imported (was it started in its old app?): \(path)\nRestore the original from your backup, or import the VM again."
        }
        return nil
    }
}

public struct DiskConfig: Codable, Equatable, Sendable {
    /// File name relative to the bundle directory.
    public var file: String
    public var sizeGiB: Int
    public var bus: DiskBus
    public var format: DiskFormat
    /// Set when this disk is a copy-on-write overlay on another image.
    public var backing: DiskBacking?

    public init(file: String, sizeGiB: Int, bus: DiskBus, format: DiskFormat, backing: DiskBacking? = nil) {
        self.file = file; self.sizeGiB = sizeGiB; self.bus = bus; self.format = format; self.backing = backing
    }
}

public enum MediaKind: String, Codable, Sendable {
    case installerISO, unattendDisk, seedISO
    /// A small CD with a driver for the guest to install (the Windows 3D display driver).
    case driverDisc
}

public struct RemovableMedia: Codable, Equatable, Sendable {
    /// Absolute path, or a path relative to the bundle directory.
    public var file: String
    public var kind: MediaKind

    public init(file: String, kind: MediaKind) { self.file = file; self.kind = kind }
}

public enum NetworkMode: String, Codable, Sendable {
    case nat
    /// The guest appears on the Mac's own network. Needs the network helper (scripts/install-net-helper.sh).
    case bridged
}

public struct PortForward: Codable, Equatable, Sendable {
    public var hostPort: Int
    public var guestPort: Int
    public init(hostPort: Int, guestPort: Int) { self.hostPort = hostPort; self.guestPort = guestPort }
}

public struct NetworkConfig: Codable, Equatable, Sendable {
    public var mode: NetworkMode
    public var mac: String
    /// Only honoured by the QEMU engine (user-mode networking has no inbound path otherwise).
    public var portForwards: [PortForward]
    /// The Mac interface a bridged VM joins, for example `en0`. Nil means the helper's first one.
    public var bridgedInterface: String? = nil

    public init(mode: NetworkMode = .nat, mac: String = NetworkConfig.randomMAC(), portForwards: [PortForward] = []) {
        self.mode = mode; self.mac = mac; self.portForwards = portForwards
    }

    /// Locally administered, unicast MAC address.
    public static func randomMAC() -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] & 0xFE) | 0x02
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

public struct DisplayConfig: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var dynamicResize: Bool
    /// QEMU Windows guests only. True once the guest has the virtio display driver, which allows real
    /// resolutions. Without the driver Windows needs the firmware framebuffer (800x600), so nil means that.
    public var virtioGPU: Bool?
    /// Linux guests on the QEMU engine only, experimental: OpenGL acceleration through virglrenderer and
    /// ANGLE (Metal), with Tandem's separate 3D build of QEMU. Nil (older configs) means off.
    public var accelerated3D: Bool?
    /// Windows guests with 3D on: the 3D display driver Tandem installed in the guest. Nil until then.
    public var windows3DDriver: Windows3DDriverState?
    public init(width: Int = 1440, height: Int = 900, dynamicResize: Bool = true, virtioGPU: Bool? = nil, accelerated3D: Bool? = nil) {
        self.width = width; self.height = height; self.dynamicResize = dynamicResize; self.virtioGPU = virtioGPU
        self.accelerated3D = accelerated3D
    }
}

/// What Tandem installed in a Windows guest for 3D acceleration.
public struct Windows3DDriverState: Codable, Equatable, Sendable {
    /// Release of the driver package, for example "0.1.274".
    public var version: String
    /// The name Windows gave the driver package ("oem12.inf"), needed to remove it again.
    public var publishedName: String?
    public init(version: String, publishedName: String?) { self.version = version; self.publishedName = publishedName }
}

public struct SharedFolder: Codable, Equatable, Sendable {
    public var hostPath: String
    public var name: String
    public var readOnly: Bool
    public init(hostPath: String, name: String, readOnly: Bool = false) {
        self.hostPath = hostPath; self.name = name; self.readOnly = readOnly
    }
}

public struct GuestToolsInfo: Codable, Equatable, Sendable {
    public var installedVersion: String?
    public var lastSeen: Date?
    /// macOS guests: the tools disc was asked for at this time and is attached at every start until the
    /// tools have answered since (`GuestTools.settleMacOSDiscRequest`).
    public var toolsDiscRequested: Date?
    /// macOS guests: the disc was attached at the last cold start, so a resume attaches it too.
    public var toolsDiscAttached: Bool?
    public init(installedVersion: String? = nil, lastSeen: Date? = nil, toolsDiscRequested: Date? = nil, toolsDiscAttached: Bool? = nil) {
        self.installedVersion = installedVersion; self.lastSeen = lastSeen
        self.toolsDiscRequested = toolsDiscRequested; self.toolsDiscAttached = toolsDiscAttached
    }
}

public enum InstallState: String, Codable, Sendable {
    case notStarted, installing, complete, failed
}

public struct InstallInfo: Codable, Equatable, Sendable {
    public var state: InstallState
    public var unattended: Bool
    public var user: String?
    /// The install disc carries the display driver, so the VM can use the faster, resizable display
    /// device once Windows is installed. Setup itself runs on the plain one.
    public var hasDisplayDriver: Bool?
    /// The account was made without a password: the VM should not be reachable from the network.
    public var passwordless: Bool?
    public init(state: InstallState = .notStarted, unattended: Bool = false, user: String? = nil, hasDisplayDriver: Bool? = nil,
                passwordless: Bool? = nil) {
        self.state = state; self.unattended = unattended; self.user = user; self.hasDisplayDriver = hasDisplayDriver
        self.passwordless = passwordless
    }
}

/// The persisted description of one VM. Stored as `config.json` in the bundle.
public struct VMConfig: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var guestOS: GuestOS
    public var engine: EngineKind
    public var cpuCount: Int
    public var memoryMiB: Int
    public var disks: [DiskConfig]
    public var removableMedia: [RemovableMedia]
    public var network: NetworkConfig
    public var display: DisplayConfig
    public var sharedFolders: [SharedFolder]
    public var guestTools: GuestToolsInfo
    public var install: InstallInfo
    /// Virtual TPM 2.0 (QEMU engine only). Windows 11 requires it.
    public var tpm: Bool
    /// Share the Mac clipboard with the guest. Nil (older configs) means on.
    public var sharedClipboard: Bool? = nil
    /// Clipboard direction, network exposure and USB access. Nil (older configs) means everything allowed.
    /// Read and written through `sharing` (SharingProfile.swift), together with `sharedFolders`.
    public var sharingRules: SharingRules? = nil
    /// Free-text description shown in the configuration window.
    public var notes: String? = nil
    /// The firmware (SMBIOS) UUID the guest sees. Nil means the VM's own `id`. An imported VM keeps the
    /// UUID it had before, because Windows counts a new one as a change of hardware when it checks activation.
    public var hardwareUUID: UUID? = nil
    /// The colour of the VM's stripe in Control Center, as `#RRGGBB`. Nil means the default for its system.
    public var color: String? = nil
    /// Guest services given a stable port and name on the Mac (PublishedServices.swift). Nil means none.
    public var publishedServices: [PublishedService]? = nil
    /// Start-up, shutdown, window, keyboard and screen behaviour (see `VMBehavior`). Nil means the defaults.
    public var behavior: VMBehavior? = nil
    /// The sound card. Nil means sound out, no microphone.
    public var sound: SoundConfig? = nil
    /// The boot order. Nil means hard disk, then CD/DVD.
    public var boot: BootConfig? = nil
    /// The idle timer and Keep Awake switch (IdlePolicy.swift). Nil means neither is on.
    public var power: PowerSettings? = nil
    /// Set on a clone whose guest still carries its source's identity (machine id, SSH host keys, computer
    /// name). The guest tools reset it the first time they connect, then this is cleared.
    public var pendingGuestIdentityReset: Bool? = nil

    public init(
        id: UUID = UUID(), name: String, guestOS: GuestOS, engine: EngineKind? = nil,
        cpuCount: Int = 4, memoryMiB: Int = 4096, disks: [DiskConfig]? = nil,
        removableMedia: [RemovableMedia] = [], network: NetworkConfig = NetworkConfig(),
        display: DisplayConfig = DisplayConfig(), sharedFolders: [SharedFolder] = [],
        guestTools: GuestToolsInfo = GuestToolsInfo(), install: InstallInfo = InstallInfo(), tpm: Bool? = nil
    ) {
        let engine = engine ?? guestOS.defaultEngine
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id; self.name = name; self.guestOS = guestOS; self.engine = engine
        self.cpuCount = cpuCount; self.memoryMiB = memoryMiB
        self.disks = disks ?? [VMConfig.defaultDisk(engine: engine, guestOS: guestOS, sizeGiB: 64)]
        self.tpm = tpm ?? (guestOS == .windows11arm)
        self.removableMedia = removableMedia; self.network = network; self.display = display
        self.sharedFolders = sharedFolders; self.guestTools = guestTools; self.install = install
    }

    /// Windows gets NVMe because it has an inbox driver for it; Linux gets virtio.
    public static func defaultDisk(engine: EngineKind, guestOS: GuestOS, sizeGiB: Int) -> DiskConfig {
        switch engine {
        case .vz: return DiskConfig(file: "disk0.img", sizeGiB: sizeGiB, bus: .virtio, format: .raw)
        case .qemu: return DiskConfig(file: "disk0.qcow2", sizeGiB: sizeGiB, bus: guestOS == .windows11arm ? .nvme : .virtio, format: .qcow2)
        }
    }

    /// Problems that would stop the VM from starting. Empty means valid.
    /// The Mac's processors and memory, as the limits for a VM's settings. `TANDEM_HOST_CPUS` and
    /// `TANDEM_HOST_MEMORY_MIB` replace them, so that the tests give the same answers on a small build machine.
    public static var hostCPUs: Int {
        ProcessInfo.processInfo.environment["TANDEM_HOST_CPUS"].flatMap { Int($0) } ?? ProcessInfo.processInfo.processorCount
    }
    public static var hostMemoryMiB: Int {
        ProcessInfo.processInfo.environment["TANDEM_HOST_MEMORY_MIB"].flatMap { Int($0) } ?? Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
    }

    public func validate(hostCPUs: Int = VMConfig.hostCPUs, hostMemoryMiB: Int = VMConfig.hostMemoryMiB) -> [String] {
        var problems: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("Name is empty.") }
        if cpuCount < 1 || cpuCount > hostCPUs { problems.append("CPU count must be 1–\(hostCPUs).") }
        if memoryMiB < 512 { problems.append("Memory must be at least 512 MiB.") }
        if memoryMiB > hostMemoryMiB { problems.append("Memory exceeds host memory (\(hostMemoryMiB) MiB).") }
        if disks.isEmpty { problems.append("At least one disk is required.") }
        if disks.contains(where: { $0.sizeGiB < 1 }) { problems.append("Disk size must be at least 1 GiB.") }
        if guestOS == .macos && engine != .vz { problems.append("macOS guests require the VZ engine.") }
        if guestOS == .windows11arm && engine != .qemu { problems.append("Windows guests require the QEMU engine.") }
        if tpm && engine != .qemu { problems.append("The virtual TPM is only available on the QEMU engine.") }
        if engine == .vz && disks.contains(where: { $0.format != .raw }) { problems.append("The VZ engine needs raw disks.") }
        if disks.contains(where: { $0.backing != nil && $0.format != .qcow2 }) { problems.append("Only qcow2 disks can have a backing file.") }
        problems += DiskPathRules.problems(in: disks)
        if schemaVersion > Self.currentSchemaVersion { problems.append("Config was written by a newer version (schema \(schemaVersion)).") }
        return problems
    }
}

extension VMConfig {
    /// Decoding tolerates fields added after a config was written, so old bundles keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        guestOS = try c.decode(GuestOS.self, forKey: .guestOS)
        engine = try c.decodeIfPresent(EngineKind.self, forKey: .engine) ?? guestOS.defaultEngine
        cpuCount = try c.decode(Int.self, forKey: .cpuCount)
        memoryMiB = try c.decode(Int.self, forKey: .memoryMiB)
        disks = try c.decode([DiskConfig].self, forKey: .disks)
        removableMedia = try c.decodeIfPresent([RemovableMedia].self, forKey: .removableMedia) ?? []
        network = try c.decodeIfPresent(NetworkConfig.self, forKey: .network) ?? NetworkConfig()
        display = try c.decodeIfPresent(DisplayConfig.self, forKey: .display) ?? DisplayConfig()
        sharedFolders = try c.decodeIfPresent([SharedFolder].self, forKey: .sharedFolders) ?? []
        guestTools = try c.decodeIfPresent(GuestToolsInfo.self, forKey: .guestTools) ?? GuestToolsInfo()
        install = try c.decodeIfPresent(InstallInfo.self, forKey: .install) ?? InstallInfo()
        tpm = try c.decodeIfPresent(Bool.self, forKey: .tpm) ?? (guestOS == .windows11arm)
        sharedClipboard = try c.decodeIfPresent(Bool.self, forKey: .sharedClipboard)
        sharingRules = try c.decodeIfPresent(SharingRules.self, forKey: .sharingRules)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        hardwareUUID = try c.decodeIfPresent(UUID.self, forKey: .hardwareUUID)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        publishedServices = try c.decodeIfPresent([PublishedService].self, forKey: .publishedServices)
        behavior = try c.decodeIfPresent(VMBehavior.self, forKey: .behavior)
        sound = try c.decodeIfPresent(SoundConfig.self, forKey: .sound)
        boot = try c.decodeIfPresent(BootConfig.self, forKey: .boot)
        power = try c.decodeIfPresent(PowerSettings.self, forKey: .power)
        pendingGuestIdentityReset = try c.decodeIfPresent(Bool.self, forKey: .pendingGuestIdentityReset)
    }
}

/// Where a VM's disk files may live. A disk is a plain file name inside the bundle (`disk0.qcow2`,
/// `data/disk1.img`). Nothing may reach outside the bundle (`..`, an absolute path, a symbolic link
/// pointing out) or land on a file the bundle needs for something else (`config.json`, `run`, `logs`…).
/// No part of Tandem makes VMs with disks elsewhere, so an absolute disk path is refused too.
public enum DiskPathRules {
    /// Names at the top of a bundle that belong to Tandem, not to a disk.
    public static let reservedNames: Set<String> = [
        VMBundle.configFileName, "run", "logs", "snapshots", "tpm", "efi-vars.fd", "machine-id.bin",
        "hardware-model.bin", "aux.img", "suspend.state", "suspend.state.zst", ".suspend.partial",
    ]

    /// Nil when `path` is an acceptable bundle-relative disk file name, otherwise the reason.
    public static func problem(with path: String) -> String? {
        if path.isEmpty { return "A disk has no file name." }
        if path.hasPrefix("/") { return "The disk “\(path)” is outside the VM; disks must be inside the VM's bundle." }
        if path.contains("\0") || path.contains("\\") { return "The disk name “\(path)” contains characters that are not allowed." }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            return "The disk “\(path)” points outside the VM's bundle."
        }
        if let first = parts.first, reservedNames.contains(first.lowercased()) || first.hasPrefix(".reverting-") || first.hasPrefix(".revert-") {
            return "The disk name “\(path)” is used by Tandem for something else."
        }
        return nil
    }

    /// Problems with every disk's file name, plus two disks sharing one file.
    public static func problems(in disks: [DiskConfig]) -> [String] {
        var problems = disks.compactMap { problem(with: $0.file) }
        var seen = Set<String>()
        for disk in disks where !seen.insert(disk.file.lowercased()).inserted {
            problems.append("Two disks use the same file “\(disk.file)”.")
        }
        return problems
    }

    /// The disk's file inside `bundle`, refusing one that a symbolic link anywhere on the way leads out of it.
    public static func containedURL(_ path: String, in bundle: URL) throws -> URL {
        if let problem = problem(with: path) { throw VMError(problem) }
        let root = bundle.resolvingSymlinksInPath().standardizedFileURL.path
        var current = bundle
        for part in path.split(separator: "/").map(String.init) {
            current.appendPathComponent(part)
            // Each existing part, links resolved, must still be inside the bundle.
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil
                || FileManager.default.fileExists(atPath: current.path) {
                let resolved = current.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved == root || resolved.hasPrefix(root + "/") else {
                    throw VMError("The disk “\(path)” leads outside the VM's bundle through a symbolic link.")
                }
            }
        }
        return current
    }
}

public enum ConfigCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
