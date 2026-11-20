import Foundation

// Everything a VM shares with the Mac, in one value, and the one place that decides what is allowed.
//
// `SharingProfile` is what the user chose and what `config.json` keeps. `TemporaryGrants` is access
// given until the VM shuts down; it lives in the running session and in a run file, never in the
// configuration. `SharingPolicy` combines the two and answers every question the app, `vmctl` and the
// engines ask. Nothing else may decide whether a folder, the clipboard, a USB device or a network path
// is open: a tool that exposes these capabilities (an MCP server, a script) has to go through it too.

/// Which way text may travel between the Mac's clipboard and the guest's.
public enum ClipboardSharing: String, Codable, CaseIterable, Sendable {
    case off, macToGuest, guestToMac, both

    public var toGuest: Bool { self == .macToGuest || self == .both }
    public var toMac: Bool { self == .guestToMac || self == .both }
    public var label: String {
        switch self {
        case .off: return "Off"
        case .macToGuest: return "Mac to virtual machine only"
        case .guestToMac: return "Virtual machine to Mac only"
        case .both: return "Both ways"
        }
    }
}

/// Who on the Mac may run commands inside the guest (`tandem exec`, the MCP tool `guest_exec`).
///
/// The Mac's own user, at the command line, already controls the VM fully (its console, its disk), so
/// letting them run a command adds no power and is on by default. An AI tool connected through the MCP
/// server is a different matter: it may act on instructions found in what it reads, so it gets this
/// power only for VMs where the user turns it on.
public enum CommandAccess: String, Codable, CaseIterable, Sendable {
    /// Nobody.
    case off
    /// The Mac's user, through the `tandem` command-line tool.
    case macUser
    /// The Mac's user and AI tools connected through `tandem mcp`.
    case macUserAndAI

    public var label: String {
        switch self {
        case .off: return "Nobody"
        case .macUser: return "The command-line tool only"
        case .macUserAndAI: return "The command-line tool and AI tools (MCP)"
        }
    }
}

/// What the guest may reach on the network and what may reach the guest.
public struct NetworkExposure: Codable, Equatable, Sendable {
    /// The guest may open connections: the Internet, the Mac's network, and services on the Mac itself.
    /// Off means no network at all, except the path to the Mac folders shared with it.
    public var outbound: Bool
    /// Connections into the guest: port forwards and published services.
    public var inbound: Bool
    /// The guest may join the Mac's own network as a device of its own (bridged mode).
    public var bridged: Bool

    public init(outbound: Bool = true, inbound: Bool = true, bridged: Bool = true) {
        self.outbound = outbound; self.inbound = inbound; self.bridged = bridged
    }
    public static let open = NetworkExposure()
}

/// The part of the profile kept beside the folder list in `config.json` (`sharingRules`).
public struct SharingRules: Codable, Equatable, Sendable {
    public var clipboard: ClipboardSharing
    public var network: NetworkExposure
    public var usb: Bool
    /// Nil (every configuration written before this existed) means the default, `.macUser`.
    public var commands: CommandAccess?
    public init(clipboard: ClipboardSharing = .both, network: NetworkExposure = .open, usb: Bool = true, commands: CommandAccess? = nil) {
        self.clipboard = clipboard; self.network = network; self.usb = usb; self.commands = commands
    }
}

/// Everything one VM shares with the Mac.
public struct SharingProfile: Codable, Equatable, Sendable {
    public var folders: [SharedFolder]
    public var clipboard: ClipboardSharing
    public var network: NetworkExposure
    /// USB devices of the Mac may be handed to the VM.
    public var usb: Bool
    /// Who may run commands inside the guest from the Mac.
    public var commands: CommandAccess

    public init(folders: [SharedFolder] = [], clipboard: ClipboardSharing = .both, network: NetworkExposure = .open, usb: Bool = true,
                commands: CommandAccess = .macUser) {
        self.folders = folders; self.clipboard = clipboard; self.network = network; self.usb = usb; self.commands = commands
    }

    private enum CodingKeys: String, CodingKey { case folders, clipboard, network, usb, commands }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folders = try c.decode([SharedFolder].self, forKey: .folders)
        clipboard = try c.decode(ClipboardSharing.self, forKey: .clipboard)
        network = try c.decode(NetworkExposure.self, forKey: .network)
        usb = try c.decode(Bool.self, forKey: .usb)
        commands = try c.decodeIfPresent(CommandAccess.self, forKey: .commands) ?? .macUser
    }

    /// What a new VM gets: nothing shared yet, everything allowed.
    public static let `default` = SharingProfile()

    /// For a disposable VM: no folders, no clipboard, no USB, nothing reaches the guest and it cannot join
    /// the Mac's network. It keeps outgoing network access, because a VM without the Internet is rarely
    /// useful for trying something out. That access goes through address translation on the Mac, so the
    /// guest can still reach servers on the Mac and its network; turning `network.outbound` off closes that.
    public static let restricted = SharingProfile(folders: [], clipboard: .off,
                                                  network: NetworkExposure(outbound: true, inbound: false, bridged: false), usb: false,
                                                  commands: .off)

    public enum Preset: String, CaseIterable, Sendable {
        case `default`, restricted
        public var profile: SharingProfile { self == .restricted ? .restricted : .default }
    }

    /// The preset this profile equals, if any.
    public var preset: Preset? {
        if self == .restricted { return .restricted }
        if self == .default { return .default }
        return nil
    }
}

extension VMConfig {
    /// The VM's sharing profile. It wraps the fields older versions wrote (`sharedFolders`,
    /// `sharedClipboard`) and the newer `sharingRules`, so configurations of any age read and write the same way.
    public var sharing: SharingProfile {
        get {
            let rules = sharingRules ?? SharingRules()
            // An older configuration, or one edited by an older build, can only say "clipboard off".
            let clipboard: ClipboardSharing = sharedClipboard == false ? .off : rules.clipboard
            return SharingProfile(folders: sharedFolders, clipboard: clipboard, network: rules.network, usb: rules.usb,
                                  commands: rules.commands ?? .macUser)
        }
        set {
            sharedFolders = newValue.folders
            // Nil (an older configuration) stays nil while the clipboard is fully shared.
            sharedClipboard = newValue.clipboard == .off ? false : (sharedClipboard == nil && newValue.clipboard == .both ? nil : true)
            let rules = SharingRules(clipboard: newValue.clipboard, network: newValue.network, usb: newValue.usb,
                                     commands: newValue.commands == .macUser ? nil : newValue.commands)
            // Keep old configurations byte-identical while nothing new is asked of them.
            sharingRules = rules == SharingRules() && sharingRules == nil ? nil : rules
        }
    }
}

/// Access given until the VM shuts down. Never written to `config.json`.
public struct TemporaryGrants: Codable, Equatable, Sendable {
    public var folders: [SharedFolder]
    /// Replaces the profile's clipboard setting while the VM runs.
    public var clipboard: ClipboardSharing?
    /// Replaces the profile's USB setting while the VM runs.
    public var usb: Bool?

    public init(folders: [SharedFolder] = [], clipboard: ClipboardSharing? = nil, usb: Bool? = nil) {
        self.folders = folders; self.clipboard = clipboard; self.usb = usb
    }
    public var isEmpty: Bool { folders.isEmpty && clipboard == nil && usb == nil }
}

/// The single point of decision for everything shared between a VM and the Mac.
public struct SharingPolicy: Equatable, Sendable {
    public var profile: SharingProfile
    public var temporary: TemporaryGrants

    public init(profile: SharingProfile, temporary: TemporaryGrants = TemporaryGrants()) {
        self.profile = profile; self.temporary = temporary
    }
    public init(_ config: VMConfig, temporary: TemporaryGrants = TemporaryGrants()) {
        self.init(profile: config.sharing, temporary: temporary)
    }

    // MARK: Folders

    public struct Folder: Equatable, Sendable {
        public var folder: SharedFolder
        /// Shared until the VM shuts down.
        public var temporary: Bool
        public var name: String { folder.name }
    }

    /// The folders the guest may see right now: the profile's, then the temporary ones. A temporary
    /// folder cannot replace or widen a folder of the profile: one with the same name or path is left out.
    public var folders: [Folder] {
        var result = profile.folders.map { Folder(folder: $0, temporary: false) }
        for extra in temporary.folders {
            let clash = result.contains { $0.folder.name.caseInsensitiveCompare(extra.name) == .orderedSame || Self.same($0.folder.hostPath, extra.hostPath) }
            if !clash { result.append(Folder(folder: extra, temporary: true)) }
        }
        return result
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
    }

    /// The shared folder that contains a Mac path, and the path inside it. The longest match wins.
    /// Nil means the guest has no access to that path.
    public func share(containing hostPath: String) -> (folder: Folder, relativePath: String)? {
        let wanted = URL(fileURLWithPath: hostPath).standardizedFileURL.pathComponents
        var best: (Folder, [String])?
        for candidate in folders {
            let root = URL(fileURLWithPath: candidate.folder.hostPath).standardizedFileURL.pathComponents
            guard wanted.count >= root.count, Array(wanted.prefix(root.count)) == root else { continue }
            if best == nil || root.count > best!.1.count { best = (candidate, root) }
        }
        guard let best else { return nil }
        return (best.0, wanted.dropFirst(best.1.count).joined(separator: "/"))
    }

    public enum FileAccess: Sendable { case read, write }

    /// Throws unless the guest may read (or write) the Mac path.
    public func requireAccess(_ access: FileAccess, toHostPath path: String) throws {
        guard let match = share(containing: path) else {
            throw VMError("“\(URL(fileURLWithPath: path).lastPathComponent)” is not in a folder shared with this virtual machine.",
                          detail: "Share its folder under Configure > Options > Sharing, then try again.")
        }
        if access == .write && match.folder.folder.readOnly {
            throw VMError("The folder “\(match.folder.name)” is shared read-only, so the virtual machine cannot change files in it.")
        }
    }

    // MARK: Clipboard

    public var clipboard: ClipboardSharing { temporary.clipboard ?? profile.clipboard }

    // MARK: USB

    public var usbAllowed: Bool { temporary.usb ?? profile.usb }

    /// Throws unless a Mac USB device may be handed to the VM.
    public func requireUSB() throws {
        guard usbAllowed else {
            throw VMError("USB devices are not shared with this virtual machine.",
                          detail: "Turn on USB access under Configure > Options > Sharing.")
        }
    }

    // MARK: Commands

    /// Who may run commands inside the guest from the Mac.
    public var commands: CommandAccess { profile.commands }

    /// Throws unless a command from this kind of Mac client may be run inside the guest.
    public func requireCommands(fromAI: Bool) throws {
        switch (profile.commands, fromAI) {
        case (.macUserAndAI, _), (.macUser, false): return
        case (.off, _):
            throw VMError("This virtual machine does not accept commands from the Mac.",
                          detail: "Allow them under Configure > Options > Sharing > Commands from the Mac.")
        case (.macUser, true):
            throw VMError("This virtual machine does not accept commands from AI tools.",
                          detail: "Allow them for this VM under Configure > Options > Sharing > Commands from the Mac.")
        }
    }

    // MARK: Network

    public var network: NetworkExposure { profile.network }

    /// Port forwards and published services may be set up for this VM.
    public var allowsInboundServices: Bool { profile.network.inbound }

    /// Throws unless a service of the guest may be made reachable from outside it.
    public func requireInboundServices() throws {
        guard allowsInboundServices else {
            throw VMError("This virtual machine’s sharing settings do not allow connections into it.",
                          detail: "Turn on “Allow connections to the virtual machine” under Configure > Options > Sharing.")
        }
    }

    /// The network configuration the engines must use: the VM's own, cut down to what the profile allows.
    /// Cutting down never fails a start; it always moves towards less exposure.
    public func enforced(_ network: NetworkConfig) -> NetworkConfig {
        var result = network
        if !profile.network.bridged && result.mode == .bridged { result.mode = .nat; result.bridgedInterface = nil }
        if !profile.network.inbound { result.portForwards = [] }
        return result
    }

    /// The whole configuration as the engines must see it.
    public func enforced(_ config: VMConfig) -> VMConfig {
        var result = config
        result.network = enforced(config.network)
        return result
    }

    /// What `enforced` changed, in plain words, for the settings panel and `vmctl sharing`.
    public func networkNotes(for network: NetworkConfig) -> [String] {
        var notes: [String] = []
        if !profile.network.bridged && network.mode == .bridged {
            notes.append("Bridged networking is chosen for this VM but not allowed here, so it uses the shared network.")
        }
        if !profile.network.inbound && !network.portForwards.isEmpty {
            notes.append("\(network.portForwards.count) port forward\(network.portForwards.count == 1 ? " is" : "s are") set up but not allowed here, so \(network.portForwards.count == 1 ? "it is" : "they are") not opened.")
        }
        if !profile.network.outbound { notes.append("The VM has no network access.") }
        return notes
    }

    // MARK: Description

    /// The effective settings, one per line.
    public func summary(network: NetworkConfig? = nil) -> [String] {
        var lines: [String] = []
        if folders.isEmpty { lines.append("Folders:    none") }
        for (index, item) in folders.enumerated() {
            let access = item.folder.readOnly ? "read-only " : "read/write"
            lines.append("\(index == 0 ? "Folders:   " : "           ") \(access)  \(item.name)  \(item.folder.hostPath)\(item.temporary ? "  (until shutdown)" : "")")
        }
        lines.append("Clipboard:  \(clipboard.label)\(temporary.clipboard != nil ? "  (until shutdown)" : "")")
        lines.append("USB:        \(usbAllowed ? "allowed" : "not allowed")\(temporary.usb != nil ? "  (until shutdown)" : "")")
        lines.append("Commands:   \(profile.commands.label)")
        lines.append("Network:    outgoing \(profile.network.outbound ? "allowed" : "blocked"), connections in \(profile.network.inbound ? "allowed" : "blocked"), bridged \(profile.network.bridged ? "allowed" : "not allowed")")
        if let network { lines += networkNotes(for: network).map { "            " + $0 } }
        if let preset = profile.preset, temporary.isEmpty { lines.append("Preset:     \(preset.rawValue)") }
        return lines
    }
}

/// The temporary grants of a running VM, kept in the bundle's `run` folder so that `vmctl` and the app
/// see the same ones. The process that runs the VM owns the file: it clears it at start and at stop.
public enum TemporarySharingFile {
    public static func url(_ bundle: VMBundle) -> URL { bundle.url.appendingPathComponent("run/temporary-sharing.json") }
    static func ownerURL(_ bundle: VMBundle) -> URL { bundle.url.appendingPathComponent("run/sharing-owner.pid") }

    public static func load(_ bundle: VMBundle) -> TemporaryGrants {
        guard let data = try? Data(contentsOf: url(bundle)),
              let grants = try? JSONDecoder().decode(TemporaryGrants.self, from: data) else { return TemporaryGrants() }
        return grants
    }

    public static func save(_ grants: TemporaryGrants, _ bundle: VMBundle) throws {
        let target = url(bundle)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if grants.isEmpty { try? FileManager.default.removeItem(at: target); return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(grants).write(to: target, options: .atomic)
    }

    public static func clear(_ bundle: VMBundle) { try? FileManager.default.removeItem(at: url(bundle)) }

    /// Records this process as the one running the VM. Temporary access can only be given while one is.
    public static func claim(_ bundle: VMBundle) {
        try? FileManager.default.createDirectory(at: ownerURL(bundle).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("\(getpid())".utf8).write(to: ownerURL(bundle), options: .atomic)
    }

    public static func release(_ bundle: VMBundle) {
        clear(bundle)
        try? FileManager.default.removeItem(at: ownerURL(bundle))
    }

    /// True while a live process (the app or `vmctl start`) is running this VM and watching the file.
    public static func hasLiveOwner(_ bundle: VMBundle) -> Bool {
        guard let text = try? String(contentsOf: ownerURL(bundle), encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

/// Changes to a sharing profile that are the same whoever makes them (the settings panel, `vmctl`).
public enum SharingEdit {
    /// A folder name the guest can use as a directory name, different from the names already taken.
    public static func uniqueName(_ wanted: String, taken: [String]) -> String {
        let cleaned = String(wanted.map { $0.isLetter || $0.isNumber || " -_.".contains($0) ? $0 : "-" }).trimmingCharacters(in: .whitespaces)
        let base = cleaned.isEmpty ? "Folder" : cleaned
        let used = Set(taken.map { $0.lowercased() })
        if !used.contains(base.lowercased()) { return base }
        return (2...99).lazy.map { "\(base) \($0)" }.first { !used.contains($0.lowercased()) } ?? base
    }

    /// Checks that a Mac path can be shared and gives it a name.
    public static func folder(path: String, name: String?, readOnly: Bool, taken: [String]) throws -> SharedFolder {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VMError("“\(path)” is not a folder on this Mac.")
        }
        return SharedFolder(hostPath: url.path, name: uniqueName(name ?? url.lastPathComponent, taken: taken), readOnly: readOnly)
    }

    /// Why an AI tool may not share `path`, or nil when it may. An AI tool must not widen its own reach,
    /// nor hand a guest the Mac user's secrets: it may share folders inside the home folder (not the home
    /// folder itself, not ~/Library, nothing hidden such as ~/.ssh) or on an external volume, and never
    /// Tandem's own library, where the VMs' settings (and so their permissions) are kept. Links are
    /// followed first, so a link to a refused place is refused too.
    public static func aiShareRefusal(path: String, home: URL, libraryRoot: URL) -> String? {
        func real(_ url: URL) -> [String] {
            url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.filter { $0 != "/" }
        }
        func starts(_ parts: [String], with prefix: [String]) -> Bool {
            parts.count >= prefix.count && zip(parts, prefix).allSatisfy { $0.compare($1, options: .caseInsensitive) == .orderedSame }
        }
        let target = real(URL(fileURLWithPath: path))
        let homeParts = real(home), library = real(libraryRoot)
        if starts(target, with: library) || starts(library, with: target) {
            return "AI tools cannot share Tandem’s own library, or a folder that contains it."
        }
        if starts(target, with: homeParts) {
            let below = Array(target.dropFirst(homeParts.count))
            guard let first = below.first else { return "AI tools cannot share the whole home folder." }
            if first.compare("Library", options: .caseInsensitive) == .orderedSame { return "AI tools cannot share the Library folder or anything in it." }
            if below.contains(where: { $0.hasPrefix(".") }) { return "AI tools cannot share hidden folders (such as .ssh or .config)." }
            return nil
        }
        if target.count >= 2, target[0] == "Volumes", !target.dropFirst().contains(where: { $0.hasPrefix(".") }) { return nil }
        return "AI tools can share folders inside the home folder or on an external disk only."
    }

    /// Removes the folders that match a name or a path. Returns how many went.
    @discardableResult
    public static func remove(_ key: String, from folders: inout [SharedFolder]) -> Int {
        let path = URL(fileURLWithPath: key).standardizedFileURL.path
        let before = folders.count
        folders.removeAll { $0.name.caseInsensitiveCompare(key) == .orderedSame || URL(fileURLWithPath: $0.hostPath).standardizedFileURL.path == path }
        return before - folders.count
    }
}
