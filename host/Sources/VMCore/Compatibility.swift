import Foundation

// What this Mac, this guest and this engine can do together, worked out before a VM is created or
// imported. The model is pure: `HostFacts` is gathered elsewhere (`HostProbe` in EngineQEMU), so every
// rule here can be unit-tested with made-up Macs.
//
// Honesty rule: a capability is `supported` only if it has been run in a real guest in this project.
// Things that are written but not run with real hardware are `unverified`; things that depend on a
// route Tandem has not built are `notSupported`, with the follow-up named.

public enum GuestArchitecture: String, Codable, Sendable, CaseIterable {
    case arm64
    case x86_64

    public var label: String { self == .arm64 ? "ARM64" : "Intel (x86-64)" }
}

/// The facts about this Mac that decide what a VM can do.
public struct HostFacts: Codable, Equatable, Sendable {
    public var chip: String
    public var isAppleSilicon: Bool
    public var macOSMajor: Int
    public var macOSMinor: Int
    public var memoryGiB: Int
    public var cores: Int
    /// Free space on the volume that holds the VM folder.
    public var freeDiskGiB: Int
    /// First line of `qemu-system-aarch64 --version`, nil when QEMU is not installed.
    public var qemuVersion: String?
    /// QEMU comes from this project's patched build (needed by some Windows builds and for suspending imported VMs).
    public var qemuIsTandemBuild: Bool
    public var swtpm: Bool
    public var zstd: Bool
    public var networkHelper: Bool
    /// Apple's Rosetta is installed (it carries the translator for Intel Linux programs as well).
    public var rosetta: Bool
    /// A virtio-win driver disc was found where Tandem looks for it.
    public var driverDisc: Bool
    public var windowsGuestTools: Bool
    public var linuxGuestTools: Bool
    public var macOSGuestTools: Bool

    public init(chip: String, isAppleSilicon: Bool, macOSMajor: Int, macOSMinor: Int, memoryGiB: Int, cores: Int, freeDiskGiB: Int,
                qemuVersion: String?, qemuIsTandemBuild: Bool, swtpm: Bool, zstd: Bool, networkHelper: Bool, rosetta: Bool,
                driverDisc: Bool, windowsGuestTools: Bool, linuxGuestTools: Bool, macOSGuestTools: Bool = false) {
        self.macOSGuestTools = macOSGuestTools
        self.chip = chip; self.isAppleSilicon = isAppleSilicon; self.macOSMajor = macOSMajor; self.macOSMinor = macOSMinor
        self.memoryGiB = memoryGiB; self.cores = cores; self.freeDiskGiB = freeDiskGiB
        self.qemuVersion = qemuVersion; self.qemuIsTandemBuild = qemuIsTandemBuild; self.swtpm = swtpm; self.zstd = zstd
        self.networkHelper = networkHelper; self.rosetta = rosetta; self.driverDisc = driverDisc
        self.windowsGuestTools = windowsGuestTools; self.linuxGuestTools = linuxGuestTools
    }

    public var macOSVersion: String { "\(macOSMajor).\(macOSMinor)" }
}

/// What is about to be created or imported.
public struct CompatibilityRequest: Equatable, Sendable {
    public var guestOS: GuestOS
    public var architecture: GuestArchitecture
    public var engine: EngineKind
    public var memoryMiB: Int?
    public var cpuCount: Int?
    /// Space the new VM needs at once (an install disc's worth for a new VM, the disk's size for a full copy).
    public var neededDiskGiB: Int?

    public init(guestOS: GuestOS, architecture: GuestArchitecture = .arm64, engine: EngineKind? = nil,
                memoryMiB: Int? = nil, cpuCount: Int? = nil, neededDiskGiB: Int? = nil) {
        self.guestOS = guestOS; self.architecture = architecture; self.engine = engine ?? guestOS.defaultEngine
        self.memoryMiB = memoryMiB; self.cpuCount = cpuCount; self.neededDiskGiB = neededDiskGiB
    }
}

public enum SupportLevel: String, Codable, Sendable {
    /// Run in a real guest in this project.
    case supported
    /// Works once something is installed; `fix` says what.
    case needsPrerequisite
    /// Works in a first form with known rough edges.
    case experimental
    /// Written, or offered by the platform, but never run by this project with the real thing.
    case unverified
    case notSupported

    public var label: String {
        switch self {
        case .supported: return "Supported"
        case .needsPrerequisite: return "Needs setup"
        case .experimental: return "Experimental"
        case .unverified: return "Unverified"
        case .notSupported: return "Not supported"
        }
    }
}

public struct CapabilityFinding: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var level: SupportLevel
    /// One plain sentence.
    public var detail: String
    /// What to do about it, when something can be done.
    public var fix: String?
    /// True when the VM cannot be created or started until this is dealt with.
    public var blocking: Bool

    public init(_ id: String, _ title: String, _ level: SupportLevel, _ detail: String, fix: String? = nil, blocking: Bool = false) {
        self.id = id; self.title = title; self.level = level; self.detail = detail; self.fix = fix; self.blocking = blocking
    }
}

public struct CompatibilityReport: Codable, Equatable, Sendable {
    public var host: HostFacts
    public var findings: [CapabilityFinding]

    public var blockers: [CapabilityFinding] { findings.filter(\.blocking) }
    public var canProceed: Bool { blockers.isEmpty }
    public func finding(_ id: String) -> CapabilityFinding? { findings.first { $0.id == id } }

    /// One line for a form row: "Ready", or what stands in the way, or how many notes there are.
    public var summary: String {
        if let first = blockers.first {
            return blockers.count == 1 ? first.title + ": " + first.level.label.lowercased() : "\(blockers.count) things must be dealt with first"
        }
        let setup = findings.filter { $0.level == .needsPrerequisite }.count
        let soft = findings.filter { $0.level == .experimental || $0.level == .unverified }.count
        var parts: [String] = ["Ready"]
        if setup > 0 { parts.append("\(setup) optional feature\(setup == 1 ? " needs" : "s need") setup") }
        if soft > 0 { parts.append("\(soft) experimental or unverified") }
        return parts.joined(separator: " · ")
    }

    /// The report as text, for `vmctl check`.
    public func text() -> String {
        var lines = ["This Mac: \(host.chip), macOS \(host.macOSVersion), \(host.memoryGiB) GB memory, \(host.cores) cores, \(host.freeDiskGiB) GB free"]
        let width = findings.map(\.title.count).max() ?? 0
        for f in findings {
            lines.append("  \(f.blocking ? "!" : " ") \(f.title.padding(toLength: width, withPad: " ", startingAt: 0))  \(f.level.label.padding(toLength: 13, withPad: " ", startingAt: 0))  \(f.detail)")
            if let fix = f.fix { lines.append("    \(String(repeating: " ", count: width + 15))  → \(fix)") }
        }
        lines.append(canProceed ? "Result: this VM can be created." : "Result: \(blockers.count) blocking problem\(blockers.count == 1 ? "" : "s").")
        return lines.joined(separator: "\n")
    }
}

public enum Compatibility {
    public static let minimumMacOS = 15

    public static func evaluate(host: HostFacts, request r: CompatibilityRequest) -> CompatibilityReport {
        var out: [CapabilityFinding] = []
        let windows = r.guestOS == .windows11arm, linux = r.guestOS == .linux, mac = r.guestOS == .macos
        let qemuEngine = r.engine == .qemu

        // 1. The Mac itself.
        if !host.isAppleSilicon {
            out.append(.init("host", "This Mac", .notSupported, "Tandem runs on Apple silicon Macs only; this Mac has an Intel processor.", blocking: true))
        } else if host.macOSMajor < minimumMacOS {
            out.append(.init("host", "This Mac", .needsPrerequisite, "Tandem needs macOS \(minimumMacOS) or later; this Mac runs \(host.macOSVersion).",
                             fix: "Update macOS in System Settings > General > Software Update.", blocking: true))
        } else {
            out.append(.init("host", "This Mac", .supported, "\(host.chip) with macOS \(host.macOSVersion) can run virtual machines."))
        }

        // 2. The guest system and its processor type.
        if r.architecture == .x86_64 {
            out.append(.init("guest", "\(osName(r.guestOS)) for Intel processors", .notSupported,
                             "Systems built for Intel (x86-64) processors cannot run: Tandem virtualizes the Mac's ARM processor and does not emulate another one.",
                             fix: "Use the ARM64 edition of the system.", blocking: true))
        } else if mac && qemuEngine {
            out.append(.init("guest", "macOS guest", .notSupported, "macOS guests run on Apple's Virtualization engine only.",
                             fix: "Choose the Virtualization engine.", blocking: true))
        } else if windows && !qemuEngine {
            out.append(.init("guest", "Windows 11 (ARM64)", .notSupported, "Windows runs on the QEMU engine only; Apple's Virtualization engine has no TPM or Windows firmware.",
                             fix: "Choose the QEMU engine.", blocking: true))
        } else if windows {
            out.append(.init("guest", "Windows 11 (ARM64)", .supported, "Installs unattended from Microsoft's ARM64 disc and runs with network, display driver and guest tools."))
        } else if linux {
            out.append(.init("guest", "Linux (ARM64)", .supported, "ARM64 Linux runs on both engines; the guest tools were run on Alpine, and an imported Kali starts."))
        } else {
            out.append(.init("guest", "macOS guest", .supported, "macOS installs from Apple's restore image and runs on Apple's Virtualization engine; you finish its setup in Apple's Setup Assistant. Guest tools for macOS do not exist yet."))
        }

        // 3. What the engine needs installed.
        if qemuEngine {
            if host.qemuVersion == nil {
                out.append(.init("qemu", "QEMU", .needsPrerequisite, "The QEMU engine is not installed.",
                                 fix: "Run scripts/build-qemu.sh (Tandem's build), or: brew install qemu", blocking: true))
            } else if !host.qemuIsTandemBuild {
                out.append(.init("qemu", "QEMU", windows ? .needsPrerequisite : .supported,
                                 windows ? "A stock QEMU is installed; some Windows 11 builds do not start with it, and imported VMs cannot be suspended."
                                         : "A stock QEMU is installed, which is enough for Linux.",
                                 fix: windows ? "Run scripts/build-qemu.sh to install Tandem's patched build." : nil))
            } else {
                out.append(.init("qemu", "QEMU", .supported, "Tandem's own QEMU build is installed."))
            }
            if windows {
                out.append(host.swtpm
                    ? .init("tpm", "TPM 2.0 chip", .supported, "Windows 11 requires a TPM; the software TPM (swtpm) is installed.")
                    : .init("tpm", "TPM 2.0 chip", .needsPrerequisite, "Windows 11 requires a TPM, and the software TPM is not installed.",
                            fix: "brew install swtpm", blocking: true))
                out.append(host.driverDisc
                    ? .init("drivers", "Windows drivers", .supported, "The driver disc for network, display and the guest tools channel was found.")
                    : .init("drivers", "Windows drivers", .needsPrerequisite, "No driver disc was found: Windows would have no network, a small fixed screen and no guest tools.",
                            fix: "Download virtio-win.iso (fedorapeople.org/groups/virt/virtio-win) into ~/Library/Application Support/Tandem."))
            }
        }

        // 4. Guest tools: most integration depends on them.
        let toolsReady = windows ? host.windowsGuestTools : linux ? host.linuxGuestTools : false
        if mac {
            out.append(host.macOSGuestTools
                ? .init("tools", "Guest tools", .unverified, "Installed from the Tandem Tools disc (Actions > Install Tandem Tools…), then kept up to date. Written and built, not yet run in a macOS VM.")
                : .init("tools", "Guest tools", .needsPrerequisite, "This copy of Tandem does not include the guest tools for macOS.",
                        fix: "Build them with scripts/build-agent.sh."))
        } else if toolsReady {
            out.append(.init("tools", "Guest tools", .supported, windows
                ? "Installed automatically with Windows and kept up to date by Tandem."
                : "Installed from the tools disc in the VM with one command (sudo sh install.sh), then kept up to date."))
        } else {
            out.append(.init("tools", "Guest tools", .needsPrerequisite, "This copy of Tandem does not include the guest tools for \(osName(r.guestOS)).",
                             fix: "Build them with scripts/build-agent.sh."))
        }

        // 5. Features.
        out.append(.init("sharedFolders", "Shared folders", mac ? .unverified : .supported,
                         mac ? "Folders are offered to macOS guests through virtiofs, which has not been run here."
                             : windows ? "Mac folders appear in Windows as drive Z: (needs the guest tools)."
                                       : "Mac folders appear under /media/mac (needs the guest tools)."))
        out.append(.init("clipboard", "Shared clipboard", mac ? (host.macOSGuestTools ? .unverified : .notSupported) : linux ? .unverified : .supported,
                         mac ? (host.macOSGuestTools ? "Text copies both ways with the guest tools (written, not yet run in a macOS VM)."
                                                      : "Needs the guest tools for macOS, which this copy of Tandem does not include.")
                             : linux ? "Text copies both ways with the guest tools in a console; picking up a desktop session's clipboard is written but was not run."
                                     : "Text copies both ways with the guest tools."))
        out.append(.init("resolution", "Display follows the window",
                         mac ? .supported : (windows && !host.driverDisc) ? .needsPrerequisite : linux ? .unverified : .supported,
                         mac ? "Apple's Virtualization engine resizes the macOS guest's display itself."
                             : windows ? (host.driverDisc ? "The Windows display resizes with the window (display driver and guest tools)."
                                                          : "Needs the display driver from the driver disc.")
                                       : "Works for a Linux desktop session through the guest tools; run only without a desktop so far."))
        out.append(.init("seamless", "Seamless Mode", windows && qemuEngine ? .experimental : .notSupported,
                         windows && qemuEngine ? "Windows programs appear as Mac windows with Dock tiles; a first form, window dragging lags and text is not Retina-sharp."
                                               : "Seamless Mode exists for Windows guests only."))
        out.append(.init("suspend", "Suspend and resume", .supported,
                         qemuEngine ? (host.zstd ? "The VM's memory is saved compressed and resumes in a few seconds."
                                                 : "Works; installing zstd (brew install zstd) makes the saved state several times smaller.")
                                    : "Apple's Virtualization engine saves and restores the VM's memory."))
        out.append(.init("snapshots", "Snapshots", .supported, "Snapshots can be taken while the VM runs or is stopped."))
        out.append(host.networkHelper
            ? .init("bridged", "Bridged networking", .supported, "The network helper is installed, so the VM can join the Mac's own network.")
            : .init("bridged", "Bridged networking", .needsPrerequisite, "Shared networking works as it is; putting the VM on the Mac's own network needs the network helper.",
                    fix: "sudo scripts/install-net-helper.sh (once)"))
        out.append(.init("usb", "USB pass-through", qemuEngine ? .unverified : .notSupported,
                         qemuEngine ? "Handing a Mac USB device to the VM is written but has never been tried with a real device."
                                    : "USB devices can be handed to VMs on the QEMU engine only."))
        out.append(.init("3d", "3D acceleration", .notSupported,
                         windows ? "Windows runs with a 2D display driver only; DirectX 11 through the driver stack UTM uses is a follow-up that has not been tried."
                                 : "The display is 2D only; accelerated 3D has not been built."))
        if linux {
            out.append(intelLinuxBinaries(host: host, engine: r.engine))
        }

        // 6. Does it fit?
        if let memory = r.memoryMiB {
            let gib = Double(memory) / 1024
            if gib > Double(host.memoryGiB) {
                out.append(.init("memory", "Memory", .notSupported, String(format: "The VM is set to %.0f GB, more than this Mac's %d GB.", gib, host.memoryGiB),
                                 fix: "Give the VM less memory.", blocking: true))
            } else if gib > Double(host.memoryGiB) * 0.75 {
                out.append(.init("memory", "Memory", .experimental, String(format: "The VM is set to %.0f GB of this Mac's %d GB; the Mac itself may become slow.", gib, host.memoryGiB),
                                 fix: "Half of the Mac's memory or less is a comfortable setting."))
            }
        }
        if let cpus = r.cpuCount, cpus > host.cores {
            out.append(.init("cpu", "Processors", .notSupported, "The VM is set to \(cpus) processors; this Mac has \(host.cores).",
                             fix: "Give the VM \(host.cores) processors or fewer.", blocking: true))
        }
        if let needed = r.neededDiskGiB, needed > host.freeDiskGiB {
            out.append(.init("disk", "Disk space", .needsPrerequisite, "About \(needed) GB is needed and \(host.freeDiskGiB) GB is free.",
                             fix: "Free some space, or choose another virtual machines folder in Preferences.", blocking: true))
        }
        return CompatibilityReport(host: host, findings: out)
    }

    /// Intel Linux programs inside an ARM Linux guest. Apple offers a translator (Rosetta) to Linux guests
    /// of its Virtualization framework; Tandem does not attach it yet, so this is never reported as available.
    static func intelLinuxBinaries(host: HostFacts, engine: EngineKind) -> CapabilityFinding {
        let title = "Intel Linux programs in this VM"
        guard engine == .vz else {
            return .init("intelLinux", title, .notSupported, "Apple's translator for Intel Linux programs is offered on its Virtualization engine only, not on QEMU.")
        }
        guard host.rosetta else {
            return .init("intelLinux", title, .needsPrerequisite, "Apple's translator (Rosetta) is not installed, and Tandem does not attach it to VMs yet.",
                         fix: "softwareupdate --install-rosetta (then it still needs support in Tandem)")
        }
        return .init("intelLinux", title, .unverified, "Rosetta is installed and Apple's engine can offer it to Linux guests, but Tandem does not attach it yet and has not verified it.")
    }

    static func osName(_ os: GuestOS) -> String {
        switch os {
        case .windows11arm: return "Windows"
        case .linux: return "Linux"
        case .macos: return "macOS"
        }
    }
}

// MARK: Installer images

/// What an installer image is, as far as can be told without mounting it.
public enum InstallerImage {
    public struct Guess: Equatable, Sendable {
        public var architecture: GuestArchitecture?
        /// How the architecture was found: "file name" or "boot files on the disc".
        public var evidence: String?
    }

    /// Hints in the file name, the way distributions and Microsoft name their images.
    public static func architecture(fromFileName name: String) -> GuestArchitecture? {
        let lower = name.lowercased()
        let tokens = lower.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        if tokens.contains(where: { ["arm64", "aarch64", "arm64e"].contains($0) }) || lower.contains("arm64") || lower.contains("aarch64") { return .arm64 }
        if tokens.contains(where: { ["x64", "amd64", "x86", "i386", "i686", "intel"].contains($0) }) || lower.contains("x86_64") || lower.contains("x86-64") { return .x86_64 }
        return nil
    }

    /// UEFI discs carry their boot loader under a fixed name per processor type: `bootaa64.efi` for ARM64,
    /// `bootx64.efi` for Intel. The names sit in the disc's directory records near its start, in ASCII
    /// (ISO 9660) or 16-bit characters (Joliet, UDF), so reading the first part of the file finds them.
    public static func architecture(scanning url: URL, limit: Int = 48 << 20) -> GuestArchitecture? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var arm = false, intel = false
        var carry = Data()
        var read = 0
        while read < limit, let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            read += chunk.count
            let block = carry + chunk
            arm = arm || containsName("BOOTAA64.EFI", in: block)
            intel = intel || containsName("BOOTX64.EFI", in: block)
            if arm && intel { break }
            carry = block.suffix(64)
        }
        // A disc with both loaders starts on either; only a disc with the Intel loader alone is Intel-only.
        if arm { return .arm64 }
        return intel ? .x86_64 : nil
    }

    private static func containsName(_ name: String, in data: Data) -> Bool {
        for variant in [name, name.lowercased()] {
            let ascii = Data(variant.utf8)
            if data.range(of: ascii) != nil { return true }
            var le = Data(), be = Data()
            for byte in ascii { le.append(byte); le.append(0); be.append(0); be.append(byte) }
            if data.range(of: le) != nil || data.range(of: be) != nil { return true }
        }
        return false
    }

    /// File name first (free), then the disc's own boot files.
    public static func inspect(_ url: URL) -> Guess {
        let fromName = architecture(fromFileName: url.lastPathComponent)
        if let scanned = architecture(scanning: url) {
            return Guess(architecture: scanned, evidence: "boot files on the disc")
        }
        return Guess(architecture: fromName, evidence: fromName == nil ? nil : "file name")
    }
}
