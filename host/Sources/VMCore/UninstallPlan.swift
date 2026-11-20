import Foundation

/// What uninstalling Tandem removes, worked out before anything is touched, so it can be shown (with
/// sizes) and confirmed. Used by Tandem > Uninstall Tandem…; scripts/uninstall.sh does the same in shell.
///
/// Three groups:
/// - always: the helper, Tandem's settings outside the library, the `tandem` link, the app itself;
/// - caches (on by default): everything in the library folder except the VMs and the library's list of
///   them (downloads, templates, installed QEMU copies, the guest tool discs, launchers);
/// - the VM library (off by default): the `.tandemvm` bundles in the VMs folder and the chosen VMs folder,
///   then the library files. VMs registered from other places are never removed; they are listed as kept.
///
/// A test library (`TANDEM_HOME`) only plans its own folder: the helper, settings, link and app belong to
/// the Mac and are left alone.
public struct UninstallPlan: Sendable {
    public enum Group: String, Sendable, CaseIterable { case system, caches, library }

    public struct Item: Sendable, Equatable, Identifiable {
        public var id: String { path }
        public var group: Group
        public var title: String
        public var path: String
        /// Bytes on disk; nil when it is not a file (a launchd job) or cannot be read.
        public var size: Int64?
        /// Owned by root: removed with one administrator prompt.
        public var needsAdministrator: Bool
        /// Moved to the Trash rather than deleted (VMs, the app).
        public var toTrash: Bool
    }

    public var items: [Item]
    /// VMs that live outside the library folders: never removed.
    public var keptVMs: [String]
    public var libraryRoot: URL
    public var vmsDirectories: [URL]
    public var isTestLibrary: Bool

    public func items(in group: Group) -> [Item] { items.filter { $0.group == group } }
    public func size(of group: Group) -> Int64 { items(in: group).compactMap(\.size).reduce(0, +) }

    public struct Inputs: Sendable {
        public var libraryRoot: URL
        public var vmsDirectory: URL
        /// Every VM the library lists (path of each bundle).
        public var bundles: [URL]
        public var isTestLibrary: Bool
        public var home: URL
        public var bundleIdentifier: String
        public var app: URL?
        public var commandLineLink: URL?
        public var macAppsFolder: URL?
        public var systemRoot: URL

        public init(libraryRoot: URL, vmsDirectory: URL, bundles: [URL], isTestLibrary: Bool, home: URL,
                    bundleIdentifier: String, app: URL?, commandLineLink: URL?, macAppsFolder: URL?, systemRoot: URL = URL(fileURLWithPath: "/")) {
            self.libraryRoot = libraryRoot; self.vmsDirectory = vmsDirectory; self.bundles = bundles
            self.isTestLibrary = isTestLibrary; self.home = home; self.bundleIdentifier = bundleIdentifier
            self.app = app; self.commandLineLink = commandLineLink; self.macAppsFolder = macAppsFolder; self.systemRoot = systemRoot
        }
    }

    /// The helper's leftovers in system folders (the script helper's files; the in-app helper lives in the app).
    public static var systemLeftovers: [String] { [
        "Library/LaunchDaemons/\(TandemIdentity.scriptHelper).plist",
        "Library/PrivilegedHelperTools/\(TandemIdentity.scriptHelper)",
        "Library/PrivilegedHelperTools/\(TandemIdentity.tool("usbredirect"))",
        "Library/PrivilegedHelperTools/\(TandemIdentity.tool("qemu-nbd"))",
    ] + [
        "var/run/tandem-net.sock",
        "var/log/tandem-nethelper.log",
        "etc/resolver/tandem.test",
    ] }

    public static func make(_ inputs: Inputs) -> UninstallPlan {
        let fm = FileManager.default
        var items: [Item] = []
        let root = inputs.libraryRoot.standardizedFileURL
        let defaultVMs = root.appendingPathComponent("VMs", isDirectory: true)
        var vmsFolders = [defaultVMs]
        if inputs.vmsDirectory.standardizedFileURL != defaultVMs { vmsFolders.append(inputs.vmsDirectory.standardizedFileURL) }

        func exists(_ url: URL) -> Bool { var isDir: ObjCBool = false; return fm.fileExists(atPath: url.path, isDirectory: &isDir) || isSymlink(url) }
        func isSymlink(_ url: URL) -> Bool { (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil }

        // 1. The Mac-wide parts.
        if !inputs.isTestLibrary {
            items.append(Item(group: .system, title: "Tandem helper (launchd job \(TandemIdentity.helper))", path: "launchd:system/\(TandemIdentity.helper)",
                              size: nil, needsAdministrator: false, toTrash: false))
            let sys = inputs.systemRoot
            for relative in systemLeftovers {
                let url = sys.appendingPathComponent(relative)
                if exists(url) {
                    items.append(Item(group: .system, title: "Helper file: /\(relative)", path: url.path,
                                      size: diskSize(url), needsAdministrator: true, toTrash: false))
                }
            }
            if let entries = try? fm.contentsOfDirectory(atPath: sys.appendingPathComponent("var/run").path) {
                for name in entries.sorted() where name.hasPrefix("tandem-net-") && name != "tandem-net.sock" {
                    let url = sys.appendingPathComponent("var/run").appendingPathComponent(name)
                    items.append(Item(group: .system, title: "Helper file: /var/run/\(name)", path: url.path, size: diskSize(url), needsAdministrator: true, toTrash: false))
                }
            }
            let library = inputs.home.appendingPathComponent("Library")
            let id = inputs.bundleIdentifier
            for (title, relative) in [("Settings", "Preferences/\(id).plist"), ("Saved window positions", "Saved Application State/\(id).savedState"),
                                      ("System caches", "Caches/\(id)"), ("Web caches", "HTTPStorages/\(id)"), ("Web data", "WebKit/\(id)")] {
                let url = library.appendingPathComponent(relative)
                if exists(url) { items.append(Item(group: .system, title: title, path: url.path, size: diskSize(url), needsAdministrator: false, toTrash: false)) }
            }
            if let link = inputs.commandLineLink, let target = try? fm.destinationOfSymbolicLink(atPath: link.path), target.contains(".app/") {
                items.append(Item(group: .system, title: "Command-line tool link", path: link.path, size: nil, needsAdministrator: false, toTrash: false))
            }
            if let app = inputs.app, exists(app) {
                items.append(Item(group: .system, title: "The app", path: app.path, size: diskSize(app), needsAdministrator: false, toTrash: true))
            }
        }

        // 2. Caches: the library folder without its VMs and its list of them.
        let keepInRoot: Set<String> = ["VMs", "registry.json", ".DS_Store"]
        if let entries = try? fm.contentsOfDirectory(atPath: root.path) {
            for name in entries.sorted() where !keepInRoot.contains(name) {
                let url = root.appendingPathComponent(name)
                if vmsFolders.contains(url.standardizedFileURL) { continue }
                items.append(Item(group: .caches, title: cacheTitle(name), path: url.path, size: diskSize(url), needsAdministrator: false, toTrash: false))
            }
        }
        if let apps = inputs.macAppsFolder, exists(apps), !apps.standardizedFileURL.path.hasPrefix(root.path + "/") {
            items.append(Item(group: .caches, title: "Launchers for Windows programs", path: apps.path, size: diskSize(apps), needsAdministrator: false, toTrash: false))
        }

        // 3. The VM library.
        var kept: [String] = []
        for bundle in inputs.bundles.map(\.standardizedFileURL).sorted(by: { $0.path < $1.path }) {
            if vmsFolders.contains(bundle.deletingLastPathComponent()) {
                items.append(Item(group: .library, title: "VM “\(bundle.deletingPathExtension().lastPathComponent)”", path: bundle.path,
                                  size: diskSize(bundle), needsAdministrator: false, toTrash: true))
            } else {
                kept.append(bundle.path)
            }
        }
        // Anything else in the VMs folders that is a VM bundle the library could not load.
        for folder in vmsFolders {
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".\(VMBundle.pathExtension)") {
                let url = folder.appendingPathComponent(name)
                if !items.contains(where: { $0.path == url.standardizedFileURL.path }) {
                    items.append(Item(group: .library, title: "VM “\(url.deletingPathExtension().lastPathComponent)”", path: url.path, size: diskSize(url), needsAdministrator: false, toTrash: true))
                }
            }
        }
        if exists(root.appendingPathComponent("registry.json")) {
            items.append(Item(group: .library, title: "The library's list of VMs", path: root.appendingPathComponent("registry.json").path, size: diskSize(root.appendingPathComponent("registry.json")), needsAdministrator: false, toTrash: false))
        }
        // A link in the home folder to the VMs folder (made by hand, like ~/Tandem).
        if !inputs.isTestLibrary, let entries = try? fm.contentsOfDirectory(atPath: inputs.home.path) {
            for name in entries.sorted() {
                let url = inputs.home.appendingPathComponent(name)
                guard let target = try? fm.destinationOfSymbolicLink(atPath: url.path) else { continue }
                let resolved = URL(fileURLWithPath: target, relativeTo: inputs.home).standardizedFileURL
                if vmsFolders.contains(resolved) || resolved == root {
                    items.append(Item(group: .library, title: "Link to the VMs folder", path: url.path, size: nil, needsAdministrator: false, toTrash: false))
                }
            }
        }
        return UninstallPlan(items: items, keptVMs: kept, libraryRoot: root, vmsDirectories: vmsFolders, isTestLibrary: inputs.isTestLibrary)
    }

    static func cacheTitle(_ name: String) -> String {
        switch name {
        case "Downloads": return "Downloads (install discs and images)"
        case "Templates": return "Templates"
        case "Guest Apps": return "Dock tiles for guest programs"
        case "Mac Applications": return "Launchers for Windows programs"
        case "control.json", "control.sock": return "Control settings (\(name))"
        default:
            if name.hasPrefix("qemu") { return "QEMU copy (\(name))" }
            if name.hasSuffix(".iso") { return "Disc image (\(name))" }
            if name.hasPrefix("tandem-agent") { return "Guest tools (\(name))" }
            return name
        }
    }

    /// Allocated size of a file or folder, not following links.
    public static func diskSize(_ url: URL) -> Int64? {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: url.path) else { return nil }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink { return 0 }
        func allocated(_ u: URL) -> Int64 {
            let values = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { return allocated(url) }
        var total: Int64 = 0
        if let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey], options: []) {
            for case let child as URL in walker { total += allocated(child) }
        }
        return total
    }
}
