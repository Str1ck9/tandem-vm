import Foundation

/// What a clone keeps from its source.
public struct CloneOptions: Equatable, Sendable {
    /// The new VM's name; nil picks "<name> Copy" (made unique).
    public var name: String?
    /// Copy the source's snapshots as well (they are clones too, so they cost little space at first).
    public var includeSnapshots: Bool
    /// Keep the suspended memory state, so the clone resumes where the source was. Risky: the guest then
    /// wakes up with the source's identity and network settings. Off by default.
    public var keepSuspendState: Bool
    /// Keep the firmware UUID, TPM and (macOS) machine identifier the guest sees. Windows uses them for its
    /// activation, so keeping them lets the clone stay activated; two VMs with the same identity should
    /// not run at the same time. Off by default: the clone is a new machine.
    public var keepHardwareIdentity: Bool
    /// Have the guest tools reset the guest's own identity at the clone's first start (Linux: machine id,
    /// SSH host keys, host name; Windows: computer name). On by default.
    public var resetGuestIdentity: Bool

    public init(name: String? = nil, includeSnapshots: Bool = false, keepSuspendState: Bool = false,
                keepHardwareIdentity: Bool = false, resetGuestIdentity: Bool = true) {
        self.name = name; self.includeSnapshots = includeSnapshots; self.keepSuspendState = keepSuspendState
        self.keepHardwareIdentity = keepHardwareIdentity; self.resetGuestIdentity = resetGuestIdentity
    }
}

/// Engine-specific steps a clone needs, provided by callers that link the engines.
public struct CloneHooks: Sendable {
    /// Points a qcow2 disk at another backing file without touching the data (`qemu-img rebase -u`).
    public var rebaseDisk: @Sendable (_ disk: URL, _ backing: String, _ format: String) throws -> Void
    /// Gives a VZ VM a new machine identifier (macOS guests need one of the right kind).
    public var renewVZMachineIdentifier: @Sendable (_ bundle: VMBundle) throws -> Void

    public init(rebaseDisk: @escaping @Sendable (URL, String, String) throws -> Void,
                renewVZMachineIdentifier: @escaping @Sendable (VMBundle) throws -> Void) {
        self.rebaseDisk = rebaseDisk; self.renewVZMachineIdentifier = renewVZMachineIdentifier
    }
}

public enum VMCloner {
    /// "<name> Copy", then "<name> Copy 2", … until it is not taken.
    public static func defaultName(for name: String, taken: Set<String>) -> String {
        let base = "\(name) Copy"
        if !taken.contains(base) { return base }
        return (2...999).lazy.map { "\(base) \($0)" }.first { !taken.contains($0) } ?? "\(base) \(UUID().uuidString.prefix(4))"
    }

    /// The clone's settings: a new VM, with what the options keep from the source.
    public static func cloneConfig(_ source: VMConfig, name: String, options: CloneOptions) -> VMConfig {
        var config = source
        config.id = UUID()
        config.name = name
        config.network.mac = NetworkConfig.randomMAC()
        // The guest sees `hardwareUUID ?? id`; keeping the identity means pinning the source's value.
        config.hardwareUUID = options.keepHardwareIdentity ? (source.hardwareUUID ?? source.id) : nil
        config.guestTools.lastSeen = nil
        let resettable = source.guestOS == .linux || source.guestOS == .windows11arm
        config.pendingGuestIdentityReset = options.resetGuestIdentity && resettable ? true : nil
        return config
    }

    /// Items of a bundle that a clone never takes over.
    static let neverCopied: Set<String> = ["run", "logs"]

    /// Clones a stopped (or suspended) VM into `directory` as an APFS copy-on-write copy. Returns the new
    /// bundle. The source is only read. Callers hold the source's lease (`BundleWork`), and run this away
    /// from the main actor: elsewhere than APFS it copies every byte. `progress` gets the fraction of the
    /// source's items copied; cancelling the calling task stops between items and removes the partial copy.
    public static func clone(_ source: VMBundle, into directory: URL, taken: Set<String>, options: CloneOptions = CloneOptions(),
                             hooks: CloneHooks, fileManager fm: FileManager = .default,
                             progress: (@Sendable (Double) -> Void)? = nil) throws -> VMBundle {
        let wanted = options.name?.trimmingCharacters(in: .whitespaces) ?? ""
        let name = wanted.isEmpty ? defaultName(for: source.config.name, taken: taken) : wanted
        guard !taken.contains(name) else { throw VMError("A VM named “\(name)” already exists.") }
        try requireSelfContainedDisks(source, includeSnapshots: options.includeSnapshots, fileManager: fm)
        let config = cloneConfig(source.config, name: name, options: options)
        let target = directory.appendingPathComponent(VMBundle.safeFileName(name) + "-" + config.id.uuidString.prefix(8).lowercased())
            .appendingPathExtension(VMBundle.pathExtension)
        guard !fm.fileExists(atPath: target.path) else { throw VMError("A VM bundle already exists at \(target.path).") }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        do {
            let items = try fm.contentsOfDirectory(atPath: source.url.path).sorted()
            for (index, item) in items.enumerated() {
                try Task.checkCancellation()
                progress?(Double(index) / Double(max(items.count, 1)))
                if neverCopied.contains(item) || item.hasPrefix(".") { continue }
                if item == "snapshots" && !options.includeSnapshots { continue }
                if VMBundle.suspendFileNames.contains(item) && !options.keepSuspendState { continue }
                if item == "tpm" && !options.keepHardwareIdentity { continue }
                try cloneItem(source.url.appendingPathComponent(item), to: target.appendingPathComponent(item))
            }
            try Task.checkCancellation()
            progress?(1)
            for dir in ["run", "logs"] {
                try fm.createDirectory(at: target.appendingPathComponent(dir), withIntermediateDirectories: true)
            }
            if !options.keepHardwareIdentity && source.config.tpm {
                // A fresh, empty TPM: swtpm sets it up at the clone's first start.
                try fm.createDirectory(at: target.appendingPathComponent("tpm"), withIntermediateDirectories: true)
            }
            var bundle = try VMBundle.load(from: target)
            bundle.config = config
            try repointBackings(in: &bundle.config, bundleURL: target, from: source.url, hooks: hooks)
            try bundle.save()
            if options.includeSnapshots { try repointSnapshots(of: bundle, from: source, hooks: hooks, fileManager: fm) }
            if !options.keepHardwareIdentity && source.config.engine == .vz {
                if source.config.guestOS == .macos {
                    try hooks.renewVZMachineIdentifier(bundle)
                } else {
                    // A generic VZ machine identifier is made afresh when the file is missing.
                    try? fm.removeItem(at: bundle.machineIdentifierURL)
                }
            }
            return bundle
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
    }

    /// A clone copies the files inside the bundle. A writable disk stored elsewhere (an absolute path, or a
    /// link leading out) would not be copied: both VMs would write the same disk and corrupt it. Such a VM
    /// is refused. Read-only backing files outside the bundle (an imported VM's original disk) are fine to
    /// share: neither VM ever writes them, and each keeps its own overlay.
    static func requireSelfContainedDisks(_ source: VMBundle, includeSnapshots: Bool, fileManager fm: FileManager) throws {
        func check(_ disks: [DiskConfig], in folder: URL, what: String) throws {
            for disk in disks {
                do { _ = try DiskPathRules.containedURL(disk.file, in: folder) }
                catch {
                    throw VMError("“\(source.config.name)” cannot be cloned: \(what) disk “\(disk.file)” is stored outside the VM.",
                                  detail: "A clone would share that disk with the original, and both would write to it. Move the disk into the VM first, or copy the VM's folder by hand.")
                }
            }
        }
        try check(source.config.disks, in: source.url, what: "its")
        guard includeSnapshots, let folders = try? fm.contentsOfDirectory(at: source.snapshotsDirectory, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(VMBundle.configFileName)),
                  let config = try? ConfigCoding.decoder().decode(VMConfig.self, from: data) else { continue }
            try check(config.disks, in: folder, what: "a snapshot's")
        }
    }

    /// Bytes allocated by a bundle's files. Right after cloning, almost all of them are shared with the
    /// source (APFS copies blocks only when either VM writes them), so callers measure the clone's real
    /// cost as the change in the volume's free space around `clone`.
    public static func allocatedBytes(of url: URL) -> UInt64 {
        var total: UInt64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let file as URL in e {
                let v = try? file.resourceValues(forKeys: Set(keys))
                if v?.isRegularFile == true { total += UInt64(v?.totalFileAllocatedSize ?? 0) }
            }
        }
        return total
    }

    /// Free bytes on the volume holding `url`.
    public static func freeBytes(at url: URL) -> Int64 {
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Copy-on-write copy of a file or folder (APFS clonefile), keeping dates so backing-disk
    /// fingerprints (size and modification time) still match.
    static func cloneItem(_ from: URL, to: URL) throws {
        // On APFS this is a clone and takes seconds; elsewhere cp copies every byte, hence the long limit.
        let result = try ToolRun.run(URL(fileURLWithPath: "/bin/cp"), ["-cRp", from.path, to.path],
                                     timeout: ToolRun.Limit.disk, output: .discard)
        guard result.succeeded else { throw ToolRun.failed(result, "“\(from.lastPathComponent)” could not be copied.") }
    }

    /// A backing file inside the source bundle becomes the clone's own copy of it: the disk's qcow2 header
    /// and the config both point into the clone, so the two VMs never share a base file path.
    static func repointBackings(in config: inout VMConfig, bundleURL: URL, from sourceURL: URL, hooks: CloneHooks) throws {
        for index in config.disks.indices {
            guard let backing = config.disks[index].backing,
                  let relative = relativePath(backing.path, inside: sourceURL) else { continue }
            let newPath = bundleURL.appendingPathComponent(relative).path
            let file = config.disks[index].file
            let disk = file.hasPrefix("/") ? URL(fileURLWithPath: file) : bundleURL.appendingPathComponent(file)
            try hooks.rebaseDisk(disk, newPath, backing.format)
            config.disks[index].backing?.path = newPath
        }
    }

    /// Snapshots carry their own config and disk copies; they get the clone's identity and backings too.
    static func repointSnapshots(of bundle: VMBundle, from source: VMBundle, hooks: CloneHooks, fileManager fm: FileManager) throws {
        guard let folders = try? fm.contentsOfDirectory(at: bundle.snapshotsDirectory, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            let configURL = folder.appendingPathComponent(VMBundle.configFileName)
            guard let data = try? Data(contentsOf: configURL),
                  var snapshotConfig = try? ConfigCoding.decoder().decode(VMConfig.self, from: data) else { continue }
            snapshotConfig.id = bundle.config.id
            snapshotConfig.name = bundle.config.name
            snapshotConfig.network.mac = bundle.config.network.mac
            snapshotConfig.hardwareUUID = bundle.config.hardwareUUID
            snapshotConfig.pendingGuestIdentityReset = bundle.config.pendingGuestIdentityReset
            for index in snapshotConfig.disks.indices {
                guard let backing = snapshotConfig.disks[index].backing,
                      let relative = relativePath(backing.path, inside: source.url) else { continue }
                // After a revert the snapshot's disk sits in the bundle root, so it points at the clone's
                // base there, not inside the snapshot folder.
                let newPath = bundle.url.appendingPathComponent(relative).path
                try hooks.rebaseDisk(folder.appendingPathComponent(snapshotConfig.disks[index].file), newPath, backing.format)
                snapshotConfig.disks[index].backing?.path = newPath
            }
            try ConfigCoding.encoder().encode(snapshotConfig).write(to: configURL, options: .atomic)
        }
    }

    static func relativePath(_ path: String, inside directory: URL) -> String? {
        let base = directory.standardizedFileURL.path + "/"
        let full = URL(fileURLWithPath: path).standardizedFileURL.path
        return full.hasPrefix(base) ? String(full.dropFirst(base.count)) : nil
    }
}

/// The command the guest tools run once in a clone so it stops sharing its source's identity.
public enum GuestIdentityReset {
    /// Host names allow letters, digits and hyphens; Windows computer names at most 15 of them.
    public static func hostName(for name: String, maxLength: Int = 63) -> String {
        let letters = name.map { ($0.isLetter || $0.isNumber) && $0.isASCII ? $0 : Character("-") }
        let collapsed = String(letters).split(separator: "-").joined(separator: "-")
        let trimmed = String(collapsed.prefix(maxLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "tandem-vm" : trimmed.lowercased()
    }

    /// Linux, as root: new machine id, new SSH host keys, the clone's host name, then a restart so every
    /// service picks them up.
    public static func linuxCommand(hostName: String) -> String {
        "truncate -s 0 /etc/machine-id; [ -L /var/lib/dbus/machine-id ] || rm -f /var/lib/dbus/machine-id; "
            + "systemd-machine-id-setup >/dev/null 2>&1 || dbus-uuidgen --ensure=/etc/machine-id; "
            + "rm -f /etc/ssh/ssh_host_*; ssh-keygen -A >/dev/null 2>&1; "
            + "hostnamectl set-hostname '\(hostName)' 2>/dev/null || echo '\(hostName)' > /etc/hostname; "
            + "sed -i 's/^127[.]0[.]1[.]1.*/127.0.1.1 \(hostName)/' /etc/hosts 2>/dev/null; "
            + "(sleep 3; systemctl reboot || reboot) >/dev/null 2>&1 &"
    }

    /// Windows, elevated: the clone's computer name, then a restart. Windows' own machine SID stays; it no
    /// longer matters outside a domain.
    public static func windowsCommand(computerName: String) -> String {
        "powershell -NoProfile -Command \"Rename-Computer -NewName '\(computerName)' -Force; shutdown /r /t 5\""
    }

    public static func command(for config: VMConfig) -> (command: String, elevated: Bool)? {
        switch config.guestOS {
        case .linux: return (linuxCommand(hostName: hostName(for: config.name)), false)
        case .windows11arm: return (windowsCommand(computerName: hostName(for: config.name, maxLength: 15).uppercased()), true)
        default: return nil
        }
    }
}
