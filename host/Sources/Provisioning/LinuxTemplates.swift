import Darwin
import Foundation
import VMCore

// Templates: a downloaded Linux system, set up once and kept, so the next VM of it is ready in seconds.
//
// How a template is made (the first time a system is chosen):
//   1. The vendor's image becomes a disk in a hidden build VM under `<library>/Templates/.build`.
//   2. That VM boots once, headless, with a setup disc that does the slow first-boot work (a desktop,
//      Kali's full kernel) but makes no account, then generalises the system (no machine id, no SSH
//      host keys, cloud-init reset so it runs again) and powers itself off.
//   3. Its disk is kept as `<library>/Templates/<option>/disk.qcow2` with a manifest.
// Every VM of that system, the first one included, is then an APFS clone of the template disk that
// is personalised on its first boot by its own setup disc: account, password or none, automatic
// sign-in, host name, guest tools. No account ever exists on a template, so no user's password or
// files can end up in one.
//
// Built from a separate VM rather than from the user's own first VM because a running VM's disk
// cannot be copied consistently, and because the user's VM has an account (and possibly files) by
// the time its setup is over. The cost is one extra boot (about 20 seconds) for the first VM.

/// What a template was made from and how.
public struct LinuxTemplateManifest: Codable, Equatable, Sendable {
    /// Bumped when the first-boot or generalising recipe changes: older templates are rebuilt.
    public static let currentRecipe = 1

    public var option: String
    public var title: String
    public var imageURL: String
    /// The vendor image's checksum (hex). A newer image means a new template.
    public var imageChecksum: String
    public var recipe: Int
    public var created: Date
    public var buildSeconds: Double
    /// The template disk's size as the guest sees it. Clones are at least this big.
    public var diskGiB: Int

    public init(option: String, title: String, imageURL: String, imageChecksum: String, recipe: Int = LinuxTemplateManifest.currentRecipe,
                created: Date = Date(), buildSeconds: Double, diskGiB: Int) {
        self.option = option; self.title = title; self.imageURL = imageURL; self.imageChecksum = imageChecksum
        self.recipe = recipe; self.created = created; self.buildSeconds = buildSeconds; self.diskGiB = diskGiB
    }

    /// Whether this template stands for that image with today's recipe.
    public func matches(option: String, imageChecksum: String) -> Bool {
        self.option == option && self.imageChecksum.lowercased() == imageChecksum.lowercased() && recipe == Self.currentRecipe
    }
}

/// The templates of one library: `<library root>/Templates`.
public struct LinuxTemplateStore: Sendable {
    public let folder: URL

    public init(libraryRoot: URL) { folder = libraryRoot.appendingPathComponent("Templates", isDirectory: true) }
    /// The store beside a download cache (`<library root>/Downloads`).
    public init(downloads: Downloader) { self.init(libraryRoot: downloads.cache.deletingLastPathComponent()) }

    public struct Entry: Sendable {
        public var manifest: LinuxTemplateManifest
        public var disk: URL
        /// Space the template's disk occupies. VMs made from it share most of it (APFS clones), so
        /// deleting the template frees less than this while such VMs exist.
        public var allocatedBytes: Int64
    }

    static let manifestName = "manifest.json", diskName = "disk.qcow2"

    func directory(for option: String) -> URL { folder.appendingPathComponent(option, isDirectory: true) }
    var buildFolder: URL { folder.appendingPathComponent(".build", isDirectory: true) }

    public func entry(for option: String) -> Entry? {
        let dir = directory(for: option)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(Self.manifestName)),
              let manifest = try? Self.decoder.decode(LinuxTemplateManifest.self, from: data) else { return nil }
        let disk = dir.appendingPathComponent(Self.diskName)
        guard FileManager.default.fileExists(atPath: disk.path) else { return nil }
        let allocated = (try? disk.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize).map(Int64.init) ?? 0
        return Entry(manifest: manifest, disk: disk, allocatedBytes: allocated)
    }

    /// The template to use for an option and image, or nil when there is none or it is out of date.
    public func usable(option: String, imageChecksum: String) -> Entry? {
        guard let entry = entry(for: option), entry.manifest.matches(option: option, imageChecksum: imageChecksum) else { return nil }
        return entry
    }

    public func list() -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().compactMap { entry(for: $0) }
    }

    public func delete(option: String) throws {
        let dir = directory(for: option)
        guard FileManager.default.fileExists(atPath: dir.path) else { throw VMError("There is no template for “\(option)”.") }
        try FileManager.default.removeItem(at: dir)
    }

    /// Moves a finished build's disk into place and records it.
    func install(disk: URL, manifest: LinuxTemplateManifest) throws {
        let fm = FileManager.default
        let dir = directory(for: manifest.option)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.moveItem(at: disk, to: dir.appendingPathComponent(Self.diskName))
        try Self.encoder.encode(manifest).write(to: dir.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    /// One build of an option at a time, also across processes (the app and `vmctl`).
    func withBuildLock<T>(option: String, _ work: () async throws -> T) async throws -> T {
        try FileManager.default.createDirectory(at: buildFolder, withIntermediateDirectories: true)
        let path = buildFolder.appendingPathComponent("\(option).lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw VMError("The template of “\(option)” could not be locked.", detail: String(cString: strerror(errno))) }
        defer { close(fd) }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try await work()
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

/// Copies a disk as an APFS clone when it can (instant, shares space), otherwise as a plain copy.
enum DiskClone {
    static func clone(_ source: URL, to target: URL) throws {
        try? FileManager.default.removeItem(at: target)
        if copyfile(source.path, target.path, nil, copyfile_flags_t(COPYFILE_CLONE_FORCE)) == 0 { return }
        // Another volume (a VM folder on an external disk): a full copy.
        try FileManager.default.copyItem(at: source, to: target)
    }
}

extension LinuxSeed.FirstBoot {
    /// The first-boot work a template does once: everything slow that is the same for every VM.
    var templateCommands: [String] {
        switch self {
        case .none: return []
        case .ubuntuDesktop(let desktop): return [Self.ubuntuDesktopInstall(desktop)]
        case .kali: return [Self.fullKernel(extraPackages: [])]
        case .kaliDesktop: return [Self.fullKernel(extraPackages: ["kali-linux-default", "kali-desktop-xfce", "lightdm"])]
        }
    }

    /// Systems whose network settings Tandem wrote itself, for any network adapter. cloud-init must
    /// then leave the network alone on the clones (it would add settings for one adapter address).
    var ownsNetwork: Bool { if case .none = self { return false } else { return true } }
}

extension LinuxSeed {
    /// Leaves a system that any number of VMs can be cloned from, then powers it off.
    static func generalise(ownsNetwork: Bool) -> String {
        var script = "set +e; "
            + "rm -f /etc/cloud/cloud-init.disabled; "
            // Every VM must get its own identity on its first boot.
            + "truncate -s 0 /etc/machine-id; [ -L /var/lib/dbus/machine-id ] || rm -f /var/lib/dbus/machine-id; "
            + "rm -f /var/lib/systemd/random-seed /etc/ssh/ssh_host_*; "
            + "sed -i '/tandem-template/d' /etc/hosts; "
        if ownsNetwork {
            script += "mkdir -p /etc/cloud/cloud.cfg.d && printf 'network: {config: disabled}\\n' > /etc/cloud/cloud.cfg.d/99-tandem-network.cfg; "
        }
        script += "command -v apt-get >/dev/null 2>&1 && apt-get clean; "
            + "command -v dnf >/dev/null 2>&1 && dnf clean all >/dev/null 2>&1; "
            + "journalctl --rotate >/dev/null 2>&1; journalctl --vacuum-time=1s >/dev/null 2>&1; "
            + "rm -rf /tmp/* /var/tmp/* /root/.bash_history; "
            // cloud-init runs again on each clone: a new instance with its own setup disc.
            + "cloud-init clean --logs --seed >/dev/null 2>&1; "
            // Freed space goes back to the host, so the template stays small.
            + "fstrim -a >/dev/null 2>&1; sync; systemctl poweroff"
        return script
    }

    /// The setup disc of a template build: the slow first-boot work, no account, then generalise.
    public static func templateUserData(firstBoot: FirstBoot) -> String {
        let steps = firstBoot.templateCommands + [generalise(ownsNetwork: firstBoot.ownsNetwork)]
        return """
        #cloud-config
        # Written by Tandem to prepare a template. No account is made: each VM made from it gets its own.
        hostname: tandem-template
        users: []
        ssh_pwauth: false
        runcmd:

        """ + steps.map { "  - [sh, -c, \(quoted($0))]\n" }.joined()
    }

    /// The setup disc of a VM cloned from a template: account, sign-in, host name, guest tools.
    public static func cloneUserData(hostName: String, account: SystemAccount, desktop: Bool) -> String {
        var steps = accountCommands(account, desktop: desktop)
        // The display manager started before the account and its automatic sign-in existed.
        if desktop { steps.append("systemctl restart display-manager >/dev/null 2>&1; true") }
        return userData(hostName: hostName, account: account, extraSteps: steps)
    }

    /// Writes a setup disc with the given user data into a bundle.
    @discardableResult
    static func build(in bundle: VMBundle, userData: String, hostName: String) throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("tandem-seed-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(userData.utf8).write(to: staging.appendingPathComponent("user-data"))
        try Data(metaData(hostName: hostName, instance: "tandem-\(bundle.id.uuidString.lowercased())").utf8)
            .write(to: staging.appendingPathComponent("meta-data"))
        let output = bundle.url.appendingPathComponent(fileName)
        try? fm.removeItem(at: output)
        try LinuxCloudImages.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                 ["makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", volumeName, "-o", output.path, staging.path])
        // It holds the account's password until the first start has finished: this user only.
        _ = chmod(output.path, 0o600)
        return output
    }
}

extension LinuxCloudImages {
    /// How long a template build may take before it is given up.
    static func buildTimeout(_ firstBoot: LinuxSeed.FirstBoot) -> TimeInterval {
        switch firstBoot {
        case .none: return 15 * 60
        case .kali: return 30 * 60
        case .ubuntuDesktop: return 60 * 60
        case .kaliDesktop: return 90 * 60
        }
    }

    /// The template disk's size: the vendor's image, but no smaller than the option's least disk.
    func templateGiB(for option: SystemOption, imageGiB: Int) -> Int { max(imageGiB, defaults(for: option).minimumDiskGiB) }

    /// Makes the template of an option: a hidden VM boots once with the template setup disc and
    /// powers itself off; its disk is kept.
    func buildTemplate(_ image: Image, source: URL, store: LinuxTemplateStore, qemuImg: URL, context: ProvisioningContext,
                       boot: @escaping BootUntilPowerOff) async throws -> LinuxTemplateStore.Entry {
        let option = image.option
        let fm = FileManager.default
        try fm.createDirectory(at: store.buildFolder, withIntermediateDirectories: true)
        let defaults = defaults(for: option)
        var config = VMConfig(name: "template-\(option.id)", guestOS: .linux, engine: .qemu,
                              cpuCount: defaults.cpuCount, memoryMiB: max(defaults.memoryMiB, 4096))
        // Clean up a build that was interrupted.
        for name in (try? fm.contentsOfDirectory(atPath: store.buildFolder.path)) ?? [] where name.hasPrefix(config.name + "-") {
            try? fm.removeItem(at: store.buildFolder.appendingPathComponent(name))
        }
        config.disks[0] = DiskConfig(file: "disk0.qcow2", sizeGiB: defaults.minimumDiskGiB, bus: .virtio, format: .qcow2)
        let bundle = try VMBundle.create(config: config, in: store.buildFolder)
        defer { try? fm.removeItem(at: bundle.url) }

        context.progress(ProvisioningProgress("Preparing the disk"))
        let disk = bundle.diskURL(bundle.config.disks[0])
        try? fm.removeItem(at: disk)
        try Self.run(qemuImg, ["convert", "-O", "qcow2", source.path, disk.path])
        let imageGiB = Int((try Self.virtualSize(of: disk, qemuImg: qemuImg) + (1 << 30) - 1) >> 30)
        let size = templateGiB(for: option, imageGiB: imageGiB)
        if size > imageGiB { try Self.run(qemuImg, ["resize", "-q", "-f", "qcow2", disk.path, "\(size)G"]) }

        var building = bundle
        building.config.disks[0].sizeGiB = size
        try LinuxSeed.build(in: building, userData: LinuxSeed.templateUserData(firstBoot: image.firstBoot), hostName: "tandem-template")
        building.config.removableMedia = [RemovableMedia(file: LinuxSeed.fileName, kind: .seedISO)]
        try building.save()
        try Task.checkCancellation()

        // The boot is the slow part (minutes for a desktop): report the time and the guest's last console line.
        let started = Date()
        let phase = "Setting up \(option.title) for the first time (later ones are ready in seconds)"
        context.progress(ProvisioningProgress(phase))
        let console = building.logsDirectory.appendingPathComponent("console.log")
        let reporter = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                let minutes = Int(Date().timeIntervalSince(started) / 60)
                let line = Self.lastConsoleLine(console).map { " · \($0)" } ?? ""
                context.progress(ProvisioningProgress(phase, detail: "\(minutes) min so far" + line))
            }
        }
        defer { reporter.cancel() }
        try await boot(building, Self.buildTimeout(image.firstBoot))
        reporter.cancel()
        try Task.checkCancellation()

        let manifest = LinuxTemplateManifest(option: option.id, title: option.title, imageURL: image.url.absoluteString,
                                             imageChecksum: image.checksum.hex, buildSeconds: Date().timeIntervalSince(started), diskGiB: size)
        try store.install(disk: disk, manifest: manifest)
        guard let entry = store.entry(for: option.id) else { throw VMError("The template of \(option.title) could not be saved.") }
        return entry
    }

    /// The last readable line the guest printed on its serial console, for progress.
    static func lastConsoleLine(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 4096 ? end - 4096 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        // Drop terminal colour codes and carriage-return redraws.
        let clean = text.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
        let lines = clean.components(separatedBy: .newlines)
            // Kernel time stamps and cloud-init's own prefix say nothing to the user.
            .map { $0.replacingOccurrences(of: #"^\s*\[\s*[0-9]+\.[0-9]+\]\s*(cloud-init\[[0-9]+\]:\s*)?"#, with: "", options: .regularExpression) }
            .map { String(String.UnicodeScalarView($0.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
                .trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 3 && !$0.hasPrefix("[") }
        return lines.last.map { String($0.prefix(80)) }
    }

    /// Turns the empty VM into a clone of the template, with its own setup disc.
    func cloneTemplate(_ entry: LinuxTemplateStore.Entry, image: Image, account: SystemAccount, bundle: inout VMBundle,
                       qemuImg: URL, context: ProvisioningContext) throws {
        guard let disk = bundle.config.disks.first, let index = bundle.config.disks.firstIndex(of: disk) else {
            throw VMError("“\(bundle.config.name)” has no disk.")
        }
        context.progress(ProvisioningProgress("Copying the prepared \(image.option.title)"))
        let target = bundle.diskURL(disk)
        try DiskClone.clone(entry.disk, to: target)
        if disk.sizeGiB > entry.manifest.diskGiB {
            try Self.run(qemuImg, ["resize", "-q", "-f", "qcow2", target.path, "\(disk.sizeGiB)G"])
        } else {
            bundle.config.disks[index].sizeGiB = entry.manifest.diskGiB
        }
        bundle.config.disks[index].format = .qcow2
        context.progress(ProvisioningProgress("Writing the setup disc"))
        let hostName = LinuxSeed.hostName(from: bundle.config.name)
        try LinuxSeed.build(in: bundle, userData: LinuxSeed.cloneUserData(hostName: hostName, account: account, desktop: image.firstBoot.isDesktop),
                            hostName: hostName)
    }
}
