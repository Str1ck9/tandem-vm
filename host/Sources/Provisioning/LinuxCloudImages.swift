import Foundation
import VMCore

/// "Download a Linux system": the distributions' own ready-made ARM64 disk images.
///
/// These are the images each vendor publishes for cloud use: an installed system on a small disk
/// that sets itself up on first boot (cloud-init). Tandem downloads one, checks it against the
/// vendor's checksum list, grows it to the size the user chose, and hands it a small setup disc
/// that makes the user's account, names the machine and installs Tandem's guest tools.
/// They are server systems: the VM's window shows a text console, not a desktop.
public struct LinuxCloudImages: SystemProvider {
    public init() {}

    public let slot = SystemCatalog.linux
    public let title = "Download a Linux system"
    public let sourceNote = "Ready-made ARM64 systems, downloaded from each distribution's own servers and checked against its published checksums. Most are server editions: the window shows a text console where you sign in with the account you choose. The “with desktop” and “Desktop” choices also install a graphical desktop on first start."
    public let guestOS = GuestOS.linux
    public let engine = EngineKind.qemu
    public let wantsAccount = true

    /// One downloadable image, resolved from the vendor's listing.
    struct Image: Equatable, Sendable {
        var option: SystemOption
        var url: URL
        var checksum: Checksum
        /// Packages and commands added to the first boot (Kali's desktop).
        var firstBoot: LinuxSeed.FirstBoot = .none
    }

    // MARK: Vendor listings

    /// Ubuntu: a `SHA256SUMS` file beside the images of each release. LTS releases, newest first.
    public static let ubuntuReleases = ["26.04", "24.04"]
    static func ubuntuBase(_ release: String) -> URL { URL(string: "https://cloud-images.ubuntu.com/releases/\(release)/release/")! }

    /// Debian: `SHA512SUMS` beside the newest build of each release. The "generic" image has the full
    /// kernel; "genericcloud" leaves out display drivers and would show nothing in the VM's window.
    static let debianReleases = [(name: "trixie", version: "13"), (name: "bookworm", version: "12")]
    static func debianBase(_ name: String) -> URL { URL(string: "https://cloud.debian.org/images/cloud/\(name)/latest/")! }

    /// Fedora: one index of every current image, with its checksum and size.
    static let fedoraIndex = URL(string: "https://fedoraproject.org/releases.json")!

    /// Kali: no ready-made ARM64 VM, but an ARM64 cloud image (a raw disk in a `.tar.xz`) with
    /// `SHA256SUMS` beside it in the "current" folder.
    static let kaliBase = URL(string: "https://kali.download/cloud-images/current/")!

    /// Both Kali choices come from the same image; the desktop one installs Kali's desktop and its
    /// standard tool set on first boot.
    static func kali(sums: String) -> [Image] {
        var best: (version: String, name: String, hex: String)?
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let hex = String(parts[0])
            let name = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            guard hex.count == 64, hex.allSatisfy(\.isHexDigit),
                  name.range(of: #"^kali-linux-[0-9]{4}\.[0-9]+-cloud-genericcloud-arm64\.tar\.xz$"#, options: .regularExpression) != nil else { continue }
            let version = String(name.dropFirst("kali-linux-".count).prefix { $0 != "-" })
            if best == nil || version.compare(best!.version, options: .numeric) == .orderedDescending { best = (version, name, hex) }
        }
        guard let best else { return [] }
        let url = kaliBase.appendingPathComponent(best.name)
        return [
            Image(option: SystemOption(id: "kali", title: "Kali Linux \(best.version)",
                                       detail: LinuxSeed.FirstBoot.kali.note),
                  url: url, checksum: .sha256(best.hex), firstBoot: .kali),
            Image(option: SystemOption(id: "kali-desktop", title: "Kali Linux \(best.version) with desktop",
                                       detail: LinuxSeed.FirstBoot.kaliDesktop.note),
                  url: url, checksum: .sha256(best.hex), firstBoot: .kaliDesktop),
        ]
    }

    /// Finds `<hex>  <name>` or `<hex> *<name>` in a checksum list.
    static func checksum(for fileName: String, in list: String) -> String? {
        for line in list.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, let hex = parts.first, let name = parts.last else { continue }
            if name == fileName || name == "*" + fileName, hex.allSatisfy(\.isHexDigit) { return String(hex) }
        }
        return nil
    }

    static func ubuntu(_ release: String, sums: String) -> Image? {
        let file = "ubuntu-\(release)-server-cloudimg-arm64.img"
        guard let hex = checksum(for: file, in: sums), hex.count == 64 else { return nil }
        return Image(option: SystemOption(id: "ubuntu-\(release)", title: "Ubuntu Server \(release) LTS",
                                          detail: "Long-term support release from Canonical"),
                     url: ubuntuBase(release).appendingPathComponent(file), checksum: .sha256(hex))
    }

    /// Ubuntu Desktop: the same official cloud image, with a desktop installed on first boot.
    /// Canonical publishes no ready-made ARM64 desktop VM image.
    static func ubuntuDesktop(from server: Image, release: String, desktop: LinuxDesktop = .gnome) -> Image {
        var option = server.option
        option.id = desktop.optionID(release: release)
        option.title = "Ubuntu Desktop \(release) LTS (\(desktop.title))"
        option.detail = LinuxSeed.FirstBoot.ubuntuDesktop(desktop).note
        option.variantGroup = "ubuntu-desktop-\(release)"
        option.variant = desktop.title
        return Image(option: option, url: server.url, checksum: server.checksum, firstBoot: .ubuntuDesktop(desktop))
    }

    static func debian(_ release: (name: String, version: String), sums: String) -> Image? {
        let file = "debian-\(release.version)-generic-arm64.qcow2"
        guard let hex = checksum(for: file, in: sums), hex.count == 128 else { return nil }
        return Image(option: SystemOption(id: "debian-\(release.version)", title: "Debian \(release.version)",
                                          detail: "Stable release “\(release.name)” from the Debian project"),
                     url: debianBase(release.name).appendingPathComponent(file), checksum: .sha512(hex))
    }

    /// The newest finished Fedora release with a generic ARM64 cloud image.
    static func fedora(index: Data) -> Image? {
        struct Entry: Decodable { var version: String; var arch: String; var link: String; var variant: String?; var subvariant: String?; var sha256: String?; var size: String? }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: index) else { return nil }
        let usable = entries.compactMap { entry -> (Int, Entry)? in
            // Betas have versions like "45 Beta" and live under /test/.
            guard entry.arch == "aarch64", entry.variant == "Cloud", entry.subvariant == "Cloud_Base", entry.link.hasSuffix(".qcow2"),
                  !entry.link.contains("/test/"), let number = Int(entry.version), let sha = entry.sha256, sha.count == 64 else { return nil }
            return (number, entry)
        }
        guard let (number, entry) = usable.max(by: { $0.0 < $1.0 }), let url = URL(string: entry.link), let sha = entry.sha256 else { return nil }
        return Image(option: SystemOption(id: "fedora-\(number)", title: "Fedora \(number) Cloud", detail: "Current release from the Fedora project",
                                          downloadBytes: entry.size.flatMap(Int64.init)),
                     url: url, checksum: .sha256(sha))
    }

    /// Asks the vendors what they have now. A vendor that cannot be reached is left out.
    func images(using downloads: Downloader) async -> [Image] {
        async let ubuntu: [Image] = {
            var found: [Image] = []
            for release in Self.ubuntuReleases {
                if let sums = try? await downloads.text(Self.ubuntuBase(release).appendingPathComponent("SHA256SUMS")),
                   let image = Self.ubuntu(release, sums: sums) { found.append(image) }
            }
            return found
        }()
        async let debian: [Image] = {
            // Only the newest Debian that answers: the older one is the fallback, not a second choice.
            for release in Self.debianReleases {
                if let sums = try? await downloads.text(Self.debianBase(release.name).appendingPathComponent("SHA512SUMS")),
                   let image = Self.debian(release, sums: sums) { return [image] }
            }
            return []
        }()
        async let fedora: [Image] = {
            guard let text = try? await downloads.text(Self.fedoraIndex), let image = Self.fedora(index: Data(text.utf8)) else { return [] }
            return [image]
        }()
        async let kali: [Image] = {
            guard let sums = try? await downloads.text(Self.kaliBase.appendingPathComponent("SHA256SUMS")) else { return [] }
            return Self.kali(sums: sums)
        }()
        // Desktop choices first (newest release first), then the server ones they are made from.
        let servers = await ubuntu
        let desktops = servers.flatMap { server -> [Image] in
            guard let release = Self.ubuntuReleases.first(where: { server.option.id == "ubuntu-\($0)" }) else { return [] }
            return LinuxDesktop.allCases.map { Self.ubuntuDesktop(from: server, release: release, desktop: $0) }
        }
        var all = desktops + servers
        all += await debian + fedora + kali
        // Sizes the listings do not give, asked of the servers themselves.
        await withTaskGroup(of: (Int, Int64?).self) { group in
            for (index, image) in all.enumerated() where image.option.downloadBytes == nil {
                group.addTask { (index, await downloads.size(of: image.url)) }
            }
            for await (index, size) in group { all[index].option.downloadBytes = size }
        }
        return all
    }

    public func options(using downloads: Downloader) async throws -> [SystemOption] {
        let found = await images(using: downloads)
        guard !found.isEmpty else {
            throw VMError("The list of Linux systems could not be loaded.",
                          detail: "None of cloud-images.ubuntu.com, cloud.debian.org, fedoraproject.org and kali.download answered. Check the Internet connection and try again.")
        }
        let store = LinuxTemplateStore(downloads: downloads)
        return found.map { image in
            var option = image.option
            if store.usable(option: option.id, imageChecksum: image.checksum.hex) != nil {
                option.detail = "Ready in seconds: a prepared copy is kept on this Mac. " + option.detail
            }
            return option
        }
    }

    private func image(for option: SystemOption, using downloads: Downloader) async throws -> Image {
        guard let image = await images(using: downloads).first(where: { $0.option.id == option.id }) else {
            throw VMError("“\(option.title)” is no longer offered for download.", detail: "Its vendor's listing could not be read, or no longer names it.")
        }
        return image
    }

    public func defaults(for option: SystemOption) -> SystemDefaults {
        // Kali's desktop and tool set take about 15 GB on their own; Ubuntu's desktop about 6 GB.
        let desktop = option.id == "kali-desktop" || option.id.hasPrefix("ubuntu-desktop-")
        return SystemDefaults(name: option.title, cpuCount: min(4, ProcessInfo.processInfo.processorCount), memoryMiB: desktop ? 8192 : 4096,
                              diskGiB: desktop ? 64 : 32, minimumDiskGiB: desktop ? 32 : (option.id == "kali" ? 25 : 8))
    }

    /// An account without a password signs in without one; `sudo` then asks for none either.
    public var allowsEmptyPassword: Bool { true }

    public func accountProblems(_ account: SystemAccount) -> [String] {
        // The password is optional: without one the account signs in without a password.
        LinuxSeed.problems(userName: account.userName) + account.passwordProblems
    }

    public func fetch(_ option: SystemOption, context: ProvisioningContext) async throws -> [URL] {
        context.progress(ProvisioningProgress("Looking up \(option.title)"))
        let image = try await image(for: option, using: context.downloads)
        return [try await context.download(DownloadRequest(url: image.url, checksum: image.checksum, expectedBytes: image.option.downloadBytes),
                                           phase: "Downloading \(option.title)")]
    }

    public func prepare(_ option: SystemOption, bundle: inout VMBundle, context: ProvisioningContext) async throws -> ProvisioningOutcome {
        guard bundle.config.guestOS == .linux, bundle.config.engine == .qemu, let disk = bundle.config.disks.first else {
            throw VMError("“\(bundle.config.name)” is not a Linux VM on the QEMU engine.")
        }
        guard let account = context.account else {
            throw VMError("A Linux system needs an account name to sign in with.")
        }
        let problems = accountProblems(account)
        guard problems.isEmpty else { throw VMError(problems.joined(separator: " ")) }
        guard let qemuImg = context.qemuImg else { throw VMError("qemu-img is needed to prepare the disk and was not found.") }

        let image = try await image(for: option, using: context.downloads)
        let store = LinuxTemplateStore(downloads: context.downloads)
        // A template already made for this image: no download, no first-boot work.
        if context.useTemplates, context.bootUntilPowerOff != nil, let entry = store.usable(option: option.id, imageChecksum: image.checksum.hex) {
            return try finish(cloning: entry, image: image, account: account, bundle: &bundle, qemuImg: qemuImg, context: context)
        }
        let downloaded = try await context.download(DownloadRequest(url: image.url, checksum: image.checksum, expectedBytes: image.option.downloadBytes),
                                                    phase: "Downloading \(option.title)")
        try Task.checkCancellation()
        // Kali ships its disk inside a compressed archive; unpack it next to the VM (sparse, a few seconds).
        var unpacked: URL?
        defer { if let unpacked { try? FileManager.default.removeItem(at: unpacked) } }
        let source: URL
        if downloaded.lastPathComponent.hasSuffix(".tar.xz") {
            context.progress(ProvisioningProgress("Unpacking \(option.title)"))
            let folder = bundle.url.appendingPathComponent(".unpack")
            unpacked = folder
            source = try Self.unpackDisk(downloaded, into: folder)
        } else {
            source = downloaded
        }
        try Task.checkCancellation()

        // Templates: set the system up once in a hidden VM, keep it, and make this VM (and later ones) a clone.
        if context.useTemplates, let boot = context.bootUntilPowerOff {
            let entry = try await store.withBuildLock(option: option.id) {
                // Another VM may have made it while this one waited.
                if let ready = store.usable(option: option.id, imageChecksum: image.checksum.hex) { return ready }
                return try await buildTemplate(image, source: source, store: store, qemuImg: qemuImg, context: context, boot: boot)
            }
            return try finish(cloning: entry, image: image, account: account, bundle: &bundle, qemuImg: qemuImg, context: context)
        }

        // The vendor's image becomes the VM's disk, in the VM's own format, then grows to the chosen size.
        // cloud-init grows the system's partition and file system into the new space on first boot.
        context.progress(ProvisioningProgress("Preparing the disk"))
        let target = bundle.diskURL(disk)
        let fresh = target.appendingPathExtension("new")
        try? FileManager.default.removeItem(at: fresh)
        try Self.run(qemuImg, ["convert", "-O", disk.format.rawValue, source.path, fresh.path])
        // A disk is never made smaller than the vendor's image (Kali's is 25 GiB): it only grows.
        let imageBytes = try Self.virtualSize(of: fresh, qemuImg: qemuImg)
        let imageGiB = Int((imageBytes + (1 << 30) - 1) >> 30)
        if imageGiB > disk.sizeGiB, let index = bundle.config.disks.firstIndex(of: disk) {
            bundle.config.disks[index].sizeGiB = imageGiB
        } else {
            try Self.run(qemuImg, ["resize", "-q", "-f", disk.format.rawValue, fresh.path, "\(disk.sizeGiB)G"])
        }
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: fresh, to: target)

        context.progress(ProvisioningProgress("Writing the setup disc"))
        try LinuxSeed.build(in: bundle, hostName: LinuxSeed.hostName(from: bundle.config.name), account: account, firstBoot: image.firstBoot)
        bundle.config.removableMedia.removeAll { $0.kind == .seedISO && $0.file == LinuxSeed.fileName }
        bundle.config.removableMedia.append(RemovableMedia(file: LinuxSeed.fileName, kind: .seedISO))
        // "Installing" until the guest tools answer; then the setup disc, which holds the password, is deleted.
        bundle.config.install = InstallInfo(state: .installing, unattended: true, user: account.userName,
                                            passwordless: account.hasPassword ? nil : true)
        try bundle.save()
        return .startNow
    }

    /// The common end of a VM made from a template: clone, setup disc, "installing" until the guest tools answer.
    private func finish(cloning entry: LinuxTemplateStore.Entry, image: Image, account: SystemAccount, bundle: inout VMBundle,
                        qemuImg: URL, context: ProvisioningContext) throws -> ProvisioningOutcome {
        try cloneTemplate(entry, image: image, account: account, bundle: &bundle, qemuImg: qemuImg, context: context)
        bundle.config.removableMedia.removeAll { $0.kind == .seedISO && $0.file == LinuxSeed.fileName }
        bundle.config.removableMedia.append(RemovableMedia(file: LinuxSeed.fileName, kind: .seedISO))
        bundle.config.install = InstallInfo(state: .installing, unattended: true, user: account.userName,
                                            passwordless: account.hasPassword ? nil : true)
        try bundle.save()
        return .startNow
    }

    /// The size a disk image presents to the guest, from `qemu-img info`.
    static func virtualSize(of image: URL, qemuImg: URL) throws -> Int64 {
        let info = try ToolRun.run(qemuImg, ["info", "--output=json", image.path], timeout: ToolRun.Limit.quick, errors: .discard)
        guard info.succeeded,
              let json = try? JSONSerialization.jsonObject(with: info.output) as? [String: Any],
              let size = (json["virtual-size"] as? NSNumber)?.int64Value else {
            throw VMError("The size of \(image.lastPathComponent) could not be read.")
        }
        return size
    }

    /// Extracts an archive holding one disk image and returns the disk. Sparse files stay sparse.
    static func unpackDisk(_ archive: URL, into folder: URL) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xJf", archive.path, "-C", folder.path])
        guard let disk = diskFile(in: folder) else {
            throw VMError("\(archive.lastPathComponent) holds no disk image.", detail: "Expected a .raw, .img or .qcow2 file inside the archive.")
        }
        return disk
    }

    /// The largest disk-image file under a folder.
    static func diskFile(in folder: URL) -> URL? {
        func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        let files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])?.compactMap { $0 as? URL } ?? [])
            .filter { ["raw", "img", "qcow2"].contains($0.pathExtension.lowercased()) }
        return files.max { size($0) < size($1) }
    }

    /// Runs a tool that works on a whole disk image (unpacking, converting, building a disc).
    static func run(_ tool: URL, _ arguments: [String], timeout: TimeInterval = ToolRun.Limit.disk) throws {
        let result = try ToolRun.run(tool, arguments, timeout: timeout, output: .discard)
        guard result.succeeded else {
            throw ToolRun.failed(result, "\(tool.lastPathComponent) \(arguments.first ?? "") failed.")
        }
    }
}

/// The setup disc of a ready-made Linux system: a "NoCloud" seed that cloud-init reads on first boot.
public enum LinuxSeed {
    public static let fileName = "seed.iso"
    /// cloud-init looks for a volume with this label.
    static let volumeName = "cidata"

    /// What Linux accepts as a login name on every distribution offered.
    public static func problems(userName: String) -> [String] {
        let ok = userName.range(of: "^[a-z_][a-z0-9_-]{0,30}$", options: .regularExpression) != nil
        var problems: [String] = []
        if !ok { problems.append("The account name must start with a lower-case letter and use only lower-case letters, digits, “-” and “_” (31 at most).") }
        if ["root", "daemon", "bin", "sys", "adm", "nobody"].contains(userName) { problems.append("That account name is reserved by Linux.") }
        return problems
    }

    /// A host name from the VM's name: lower-case letters, digits and hyphens, 63 at most.
    public static func hostName(from name: String) -> String {
        let mapped = name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let joined = String(mapped).split(separator: "-").joined(separator: "-")
        // Cut to 63, then no hyphen left at the end ("a…a-b" cut after the hyphen).
        let cut = String(joined.prefix(63)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cut.isEmpty ? "tandem-vm" : cut
    }

    /// A double-quoted string that is valid JSON and valid YAML 1.1 (cloud-init's PyYAML) alike, for
    /// whatever the user typed. JSONEncoder's output was not enough: it leaves DEL and the C1 controls
    /// raw, which YAML refuses ("control characters are not allowed"), so a password with one of them
    /// broke the whole first boot (found by the fuzz tests). Line and paragraph separators are escaped
    /// too, as YAML 1.1 counts them as line breaks.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                let v = scalar.value
                if v < 0x20 || (0x7F...0x9F).contains(v) || v == 0x2028 || v == 0x2029 || v == 0xFEFF || v == 0xFFFE || v == 0xFFFF {
                    out += String(format: "\\u%04X", v)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Extra work for the first boot, after the account and guest tools.
    public enum FirstBoot: Equatable, Sendable {
        case none
        /// Kali's cloud image has a cloud kernel: no display, no USB keyboard or mouse, no USB discs.
        /// The guest tools come from the setup disc instead (a virtio disk it can read), then the full
        /// kernel replaces the cloud one and the VM restarts into a console on its own screen.
        case kali
        /// As `kali`, plus Kali's Xfce desktop and its standard tool set, restarting into the graphical login.
        case kaliDesktop
        /// A desktop (MATE, Xfce or Ubuntu's own GNOME) on Ubuntu's server cloud image, on X11 so the
        /// guest tools can share the clipboard and follow the window size, restarting into the graphical login.
        case ubuntuDesktop(LinuxDesktop)

        public var note: String {
            switch self {
            case .none: return ""
            case .kali:
                return "Penetration-testing system from the Kali project, text console; add tools with apt. Ready about a minute after the download (it restarts once)."
            case .ubuntuDesktop(let desktop):
                return desktop.note
            case .kaliDesktop:
                return "Kali’s Xfce desktop and standard tools, installed on first start. The guest tools connect within a minute, then the desktop takes about 10 minutes more (it downloads about 2.8 GB; longer on a slow connection) and the VM restarts into the graphical login."
            }
        }

        /// Whether the guest tools go on the setup disc as well (Kali's cloud kernel cannot read the tools disc).
        var toolsOnSeed: Bool { self == .kali || self == .kaliDesktop }
        /// Starts in a graphical login, so automatic sign-in goes to the display manager, not the console.
        var isDesktop: Bool {
            switch self {
            case .ubuntuDesktop, .kaliDesktop: return true
            case .none, .kali: return false
            }
        }

        /// A desktop on Ubuntu's server image. The guest tools use X for the clipboard (xclip) and the
        /// window size (xrandr). MATE and Xfce are X11 desktops signed in through LightDM. For GNOME, GDM is
        /// told to start X11 sessions: 24.04 honours that; 26.04's GNOME has no X11 session and stays on
        /// Wayland, where clipboard and resizing were seen working through Xwayland.
        static func ubuntuDesktopInstall(_ desktop: LinuxDesktop) -> String {
            "export DEBIAN_FRONTEND=noninteractive; "
            + desktop.preInstall
            + "apt-get update && apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "
            + "install \(desktop.packages.joined(separator: " ")) xclip x11-xserver-utils && "
            + desktop.postInstall
            // The desktop brings NetworkManager, while cloud-init left the network to systemd-networkd; with
            // both, every boot waited two minutes for networkd to call the network "online". Hand it all to
            // NetworkManager, as a desktop install would have it.
            + "rm -f /etc/netplan/50-cloud-init.yaml && "
            + "printf 'network:\\n  version: 2\\n  renderer: NetworkManager\\n' > /etc/netplan/01-network-manager-all.yaml && "
            + "chmod 600 /etc/netplan/01-network-manager-all.yaml && netplan generate && "
            + "systemctl disable systemd-networkd-wait-online.service systemd-networkd.service >/dev/null 2>&1; "
            // The setup disc holds the password: keep it off the desktop and out of the file manager.
            + "printf 'ENV{ID_FS_LABEL}==\"cidata\", ENV{UDISKS_IGNORE}=\"1\"\\n' > /etc/udev/rules.d/99-tandem-hide-setup-disc.rules; "
            + "systemctl set-default graphical.target; true"
        }

        /// Installs the guest tools from the setup disc (labelled `cidata`).
        static let installToolsFromSeed = """
        d=$(blkid -L \(LinuxSeed.volumeName) 2>/dev/null); mkdir -p /run/tandem-seed; \
        if [ -n "$d" ] && mount -o ro "$d" /run/tandem-seed; then \
        [ -f /run/tandem-seed/tandem-tools/install.sh ] && sh /run/tandem-seed/tandem-tools/install.sh; \
        umount /run/tandem-seed; fi; true
        """

        /// Replaces the cloud kernel with the full one and stops the console signing in as root by itself.
        static func fullKernel(extraPackages: [String]) -> String {
            let packages = (["linux-image-arm64"] + extraPackages).joined(separator: " ")
            return "export DEBIAN_FRONTEND=noninteractive; "
                + "apt-get update && apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install \(packages) && "
                + "echo 'linux-base linux-base/removing-running-kernel boolean false' | debconf-set-selections && "
                + "apt-get -y purge $(dpkg-query -W -f '${Package}\\n' 'linux-*cloud-arm64*' 2>/dev/null); "
                // Kali splits a kernel into image, binary, modules and base packages; all the cloud ones
                // must go, or the boot menu still lists the cloud kernel first and starts it.
                + "ls /boot/vmlinuz-*cloud* >/dev/null 2>&1 && rm -f /boot/*-*cloud-arm64 && update-grub; "
                // The cloud image signs in as root by itself on the serial line and the first screen.
                + "rm -f /etc/systemd/system/serial-getty@.service.d/autologin.conf /etc/systemd/system/getty@tty1.service.d/autologin.conf; "
                // Its network settings are written by cloud-init into /run on every boot; with cloud-init
                // switched off after the first one, the network would stay down. Make them permanent.
                + "printf '[Match]\\nName=en* eth*\\n\\n[Network]\\nDHCP=yes\\n' > /etc/systemd/network/20-tandem-wired.network; "
                + "systemctl enable systemd-networkd >/dev/null 2>&1; "
                + (extraPackages.isEmpty ? "" : "systemctl set-default graphical.target; ")
                + "update-grub; true"
        }

        var commands: [String] {
            switch self {
            case .none: return []
            case .kali:
                return [Self.installToolsFromSeed, Self.fullKernel(extraPackages: []), "systemctl reboot"]
            case .ubuntuDesktop(let desktop):
                return [Self.ubuntuDesktopInstall(desktop), "systemctl reboot"]
            case .kaliDesktop:
                return [Self.installToolsFromSeed,
                        Self.fullKernel(extraPackages: ["kali-linux-default", "kali-desktop-xfce", "lightdm"]),
                        "systemctl reboot"]
            }
        }
    }

    /// Mounts Tandem's guest tools disc (attached to every Linux guest) and runs its installer.
    static let installTools = """
    for d in $(blkid -L \(GuestTools.linuxVolumeName) 2>/dev/null) /dev/sr0 /dev/sr1 /dev/sr2; do \
    [ -b "$d" ] || continue; mkdir -p /run/tandem-tools; \
    if mount -o ro "$d" /run/tandem-tools 2>/dev/null; then \
    if [ -f /run/tandem-tools/install.sh ]; then sh /run/tandem-tools/install.sh; umount /run/tandem-tools; break; fi; \
    umount /run/tandem-tools; fi; done; true
    """

    /// Account set-up that cloud-init's `users` cannot express: no password, and automatic sign-in.
    static func accountCommands(_ account: SystemAccount, desktop: Bool) -> [String] {
        let user = account.userName
        var commands: [String] = []
        if !account.hasPassword {
            // No password at all. Console and desktop sign-in accept an empty one (PAM nullok; Fedora's
            // authselect needs it switched on); remote logins with an empty password stay refused.
            commands.append(#"passwd -d \#(user); "#
                + #"command -v authselect >/dev/null 2>&1 && authselect enable-feature with-nullok >/dev/null 2>&1; "#
                + #"mkdir -p /etc/ssh/sshd_config.d && printf 'PermitEmptyPasswords no\n' > /etc/ssh/sshd_config.d/50-tandem-no-empty-passwords.conf; true"#)
        }
        if desktop {
            // The account was set up by Tandem already: skip GNOME's own first-run welcome questions.
            commands.append(#"mkdir -p /home/\#(user)/.config && echo yes > /home/\#(user)/.config/gnome-initial-setup-done && "#
                + #"chown -R \#(user): /home/\#(user)/.config; true"#)
        }
        guard account.autoLogin else { return commands }
        if desktop {
            // GDM (Ubuntu) and LightDM (Kali); written after the desktop is installed, before its restart.
            commands.append(#"if [ -f /etc/gdm3/custom.conf ]; then sed -i '/^AutomaticLogin/d' /etc/gdm3/custom.conf; "#
                + #"grep -q '^\[daemon\]' /etc/gdm3/custom.conf || printf '[daemon]\n' >> /etc/gdm3/custom.conf; "#
                + #"sed -i 's/^\[daemon\]$/[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=\#(user)/' /etc/gdm3/custom.conf; fi; "#
                + #"if [ -d /etc/lightdm ]; then mkdir -p /etc/lightdm/lightdm.conf.d; "#
                + #"printf '[Seat:*]\nautologin-user=\#(user)\nautologin-user-timeout=0\n' > /etc/lightdm/lightdm.conf.d/50-tandem-autologin.conf; "#
                + #"groupadd -r -f autologin; gpasswd -a \#(user) autologin >/dev/null; fi; true"#)
        } else {
            // The screen's first console and the serial line sign the account in by themselves.
            commands.append(#"for unit in getty@tty1 serial-getty@ttyAMA0; do mkdir -p /etc/systemd/system/$unit.service.d; done; "#
                + #"printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin \#(user) --noclear %%I $TERM\n' "#
                + #"> /etc/systemd/system/getty@tty1.service.d/50-tandem-autologin.conf; "#
                + #"printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin \#(user) --keep-baud 115200,57600,38400,9600 - $TERM\n' "#
                + #"> /etc/systemd/system/serial-getty@ttyAMA0.service.d/50-tandem-autologin.conf; "#
                + #"systemctl daemon-reload; systemctl restart getty@tty1 serial-getty@ttyAMA0 >/dev/null 2>&1; true"#)
        }
        return commands
    }

    public static func userData(hostName: String, account: SystemAccount, firstBoot: FirstBoot = .none) -> String {
        // Account commands run after the first-boot work (a desktop must exist before its sign-in is set),
        // but before a closing restart, which would end the run.
        var steps = firstBoot.commands
        let restart = steps.last == "systemctl reboot" ? steps.removeLast() : nil
        steps += accountCommands(account, desktop: firstBoot.isDesktop)
        if let restart { steps.append(restart) }
        return userData(hostName: hostName, account: account, extraSteps: steps)
    }

    /// The account, guest tools and host name every downloaded system gets, then `extraSteps`.
    static func userData(hostName: String, account: SystemAccount, extraSteps steps: [String]) -> String {
        let extra = steps.map { "  - [sh, -c, \(quoted($0))]\n" }.joined()
        let password = account.hasPassword ? "    plain_text_passwd: \(quoted(account.password))\n" : ""
        // Without a password, sudo must not ask for one either.
        let sudo = account.hasPassword ? "ALL=(ALL) ALL" : "ALL=(ALL) NOPASSWD:ALL"
        return """
        #cloud-config
        # Written by Tandem for the first boot of a downloaded system. This disc is deleted afterwards.
        hostname: \(quoted(hostName))
        preserve_hostname: false
        ssh_pwauth: true
        users:
          - name: \(quoted(account.userName))
            gecos: \(quoted(account.userName))
            shell: /bin/bash
            lock_passwd: false
        \(password)    sudo: "\(sudo)"
        chpasswd:
          expire: false
        runcmd:
          - [sh, -c, \(quoted(installTools))]
          # First boot is done: cloud-init has nothing more to do here, and must not act again
          # when the setup disc is gone.
          - [sh, -c, "touch /etc/cloud/cloud-init.disabled"]

        """ + extra
    }

    public static func metaData(hostName: String, instance: String) -> String {
        "instance-id: \(instance)\nlocal-hostname: \(hostName)\n"
    }

    /// Lays the two files out in a folder. Separate from `build` so it can be tested without `hdiutil`.
    public static func stage(in directory: URL, hostName: String, account: SystemAccount, instance: String, firstBoot: FirstBoot = .none) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(userData(hostName: hostName, account: account, firstBoot: firstBoot).utf8).write(to: directory.appendingPathComponent("user-data"))
        try Data(metaData(hostName: hostName, instance: instance).utf8).write(to: directory.appendingPathComponent("meta-data"))
    }

    /// Writes `seed.iso` into the bundle and returns its URL. Replaces an existing one.
    @discardableResult
    public static func build(in bundle: VMBundle, hostName: String, account: SystemAccount, firstBoot: FirstBoot = .none) throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("tandem-seed-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try stage(in: staging, hostName: hostName, account: account, instance: "tandem-\(bundle.id.uuidString.lowercased())", firstBoot: firstBoot)
        if firstBoot.toolsOnSeed {
            guard let agent = GuestTools.linuxAgent else { throw VMError("Tandem's guest tools for Linux are missing from this build.") }
            try GuestTools.stageLinux(agent: agent, in: staging.appendingPathComponent("tandem-tools"))
        }
        let output = bundle.url.appendingPathComponent(fileName)
        try? fm.removeItem(at: output)
        try LinuxCloudImages.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                 ["makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", volumeName, "-o", output.path, staging.path])
        // It holds the account's password until the first start has finished: this user only.
        _ = chmod(output.path, 0o600)
        return output
    }
}
