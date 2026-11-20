import Foundation
import VMCore

/// Files dropped from the Mac onto a guest window, and files the guest sends back.
///
/// Mac to guest: the dropped files are copied (APFS clones, so instantly on the same volume) into a
/// folder of the VM's bundle, which the VM's share server serves under a hidden name. The guest tools
/// are told where the drop landed and which files to fetch; they decide the folder (the Explorer
/// window or desktop under the pointer, otherwise the user's Downloads), fetch the files over HTTP,
/// and report back. The staging copy is deleted when the guest has answered, and at VM start and stop.
///
/// Guest to Mac: the guest tools upload into a second hidden, writable share and finish with a
/// manifest file `<id>.done`; the host moves the files to the Mac's Downloads folder.
public enum FileDrop {
    /// Hidden share names. Not announced to the guest and not listed at the server's root.
    public static let dropShare = "TandemDrop"
    public static let inboxShare = "TandemInbox"

    public static func dropRoot(_ bundle: VMBundle) -> URL { bundle.url.appendingPathComponent("run/drops", isDirectory: true) }
    public static func inboxRoot(_ bundle: VMBundle) -> URL { bundle.url.appendingPathComponent("run/inbox", isDirectory: true) }

    /// One entry of a drop: a path below the drop share (`<drop id>/<name>[/<below>]`).
    public struct Item: Codable, Equatable, Sendable {
        public var path: String
        public var size: UInt64
        public var directory: Bool
        public init(path: String, size: UInt64, directory: Bool) { self.path = path; self.size = size; self.directory = directory }
    }

    /// What the guest tools are sent with a drop.
    public struct Manifest: Codable, Equatable, Sendable {
        public var id: String
        public var port: Int
        public var share: String
        public var items: [Item]
        public var totalBytes: UInt64 { items.reduce(0) { $0 + $1.size } }
        /// The top-level names, for messages ("report.pdf and 2 more").
        public var topLevel: [String] {
            items.compactMap { item in
                let parts = item.path.split(separator: "/")
                return parts.count == 2 ? String(parts[1]) : nil
            }
        }
        public init(id: String, port: Int, share: String = FileDrop.dropShare, items: [Item]) {
            self.id = id; self.port = port; self.share = share; self.items = items
        }

        /// The form the guest tools read (PROTOCOL.md "file drop"): a header line, then one line per
        /// item, tab-separated, with paths percent-encoded (so they can go into a URL as they are).
        ///
        ///     tandem-drop 1
        ///     <id>\t<port>\t<share>
        ///     d\t<path>            a folder
        ///     f\t<size>\t<path>    a file
        public var guestText: String {
            var lines = ["tandem-drop 1", "\(id)\t\(port)\t\(share)"]
            for item in items {
                let path = FileDrop.encodePath(item.path)
                lines.append(item.directory ? "d\t\(path)" : "f\t\(item.size)\t\(path)")
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    /// Percent-encodes everything in a path except unreserved characters and `/`.
    public static func encodePath(_ path: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        allowed.formIntersection(.urlPathAllowed)
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    /// Copies the dropped files and folders into `root/<id>/` and lists what the guest must fetch,
    /// folders before their contents. Symbolic links are followed for the dropped items themselves and
    /// skipped inside dropped folders (a link could point anywhere on the Mac).
    public static func stage(_ urls: [URL], in root: URL, id: String = String(UUID().uuidString.prefix(8)).lowercased()) throws -> Manifest {
        let fm = FileManager.default
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var items: [Item] = []
        var used = Set<String>()
        do {
            for source in urls {
                let resolved = source.resolvingSymlinksInPath()
                var name = source.lastPathComponent
                // Two dropped items with the same name (from different folders) must not overwrite each other.
                var n = 2
                while used.contains(name.lowercased()) { name = numbered(source.lastPathComponent, n); n += 1 }
                used.insert(name.lowercased())
                let target = folder.appendingPathComponent(name)
                try fm.copyItem(at: resolved, to: target)   // clonefile on APFS
                var isDirectory: ObjCBool = false
                fm.fileExists(atPath: target.path, isDirectory: &isDirectory)
                if isDirectory.boolValue {
                    items.append(Item(path: "\(id)/\(name)", size: 0, directory: true))
                    items += try contents(of: target, relativeTo: folder, id: id)
                } else {
                    items.append(Item(path: "\(id)/\(name)", size: size(of: target), directory: false))
                }
            }
        } catch {
            try? fm.removeItem(at: folder)
            throw VMError("The dropped files could not be prepared for the virtual machine.", detail: error.localizedDescription)
        }
        return Manifest(id: id, port: 0, items: items)
    }

    private static func contents(of directory: URL, relativeTo base: URL, id: String) throws -> [Item] {
        let fm = FileManager.default
        var items: [Item] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [] }
        let basePath = base.standardizedFileURL.resolvingSymlinksInPath().path
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { continue }
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(basePath + "/") else { continue }
            let relative = String(full.dropFirst(basePath.count + 1))
            items.append(Item(path: "\(id)/\(relative)", size: values.isDirectory == true ? 0 : UInt64(values.fileSize ?? 0),
                              directory: values.isDirectory == true))
        }
        return items
    }

    private static func size(of url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
    }

    /// "report.pdf", 2 → "report 2.pdf".
    public static func numbered(_ name: String, _ n: Int) -> String {
        let ext = URL(fileURLWithPath: name).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        return ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
    }

    public static func discard(_ id: String, in root: URL) {
        guard !id.isEmpty, !id.contains("/"), !id.contains("..") else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id))
    }

    /// Removes everything staged or half-received for a VM (at start and stop).
    /// Arrivals that could not be delivered nor kept elsewhere (`<id>.failed`) stay, so nothing the guest
    /// sent is lost.
    public static func clear(_ bundle: VMBundle) {
        let fm = FileManager.default
        try? fm.removeItem(at: dropRoot(bundle))
        let inbox = inboxRoot(bundle)
        let entries = (try? fm.contentsOfDirectory(atPath: inbox.path)) ?? []
        let held = Set(entries.filter { $0.hasSuffix(".failed") }.map { String($0.dropLast(7)) })
        guard !held.isEmpty else { try? fm.removeItem(at: inbox); return }
        for entry in entries where !entry.hasSuffix(".failed") && !held.contains(entry) {
            try? fm.removeItem(at: inbox.appendingPathComponent(entry))
        }
    }

    // MARK: Guest to Mac

    /// A finished upload: the guest wrote `<id>/…` and then `<id>.done` listing the top-level names.
    public struct Arrival: Equatable, Sendable {
        public var id: String
        public var names: [String]
    }

    /// Uploads the guest has finished. The manifest is one name per line (UTF-8).
    public static func finishedArrivals(in inbox: URL) -> [Arrival] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: inbox.path)) ?? []
        return entries.filter { $0.hasSuffix(".done") }.sorted().compactMap { file in
            let id = String(file.dropLast(5))
            // Files dragged out of a guest window belong to the drop on the Mac that asked for them.
            guard !id.hasPrefix("dragout-") else { return nil }
            guard !id.isEmpty, !id.contains("/"), let data = fm.contents(atPath: inbox.appendingPathComponent(file).path) else { return nil }
            let names = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
                .filter { !$0.isEmpty && !$0.contains("/") && $0 != "." && $0 != ".." }
            return Arrival(id: id, names: names)
        }
    }

    /// What happened to one arrival.
    public struct Delivery: Equatable, Sendable {
        /// Files now in the destination.
        public var delivered: [URL] = []
        /// Files that could not be put in the destination, kept here instead (nothing is deleted).
        public var kept: [URL] = []
        /// "name: reason" for each file that did not reach the destination.
        public var failures: [String] = []
        /// True when files that failed could not be kept outside the inbox either; they stay there,
        /// under `<id>.failed`, and survive the VM's stop.
        public var leftInInbox = false
        public var complete: Bool { failures.isEmpty }
        public init() {}
    }

    /// Moves an arrival into `destination` (the Mac's Downloads), renaming where a file of that name
    /// exists. The inbox copy of a file is removed only once that file is in the destination. Files that
    /// cannot be delivered are moved into `keepRoot/<id>/` (with a note saying why), or, failing that,
    /// left in the inbox with their manifest renamed to `<id>.failed`, so they are neither retried in a
    /// loop nor removed when the VM stops.
    @discardableResult
    public static func deliver(_ arrival: Arrival, from inbox: URL, to destination: URL, keepIn keepRoot: URL? = nil) -> Delivery {
        let fm = FileManager.default
        let folder = inbox.appendingPathComponent(arrival.id, isDirectory: true)
        let manifest = inbox.appendingPathComponent(arrival.id + ".done")
        var result = Delivery()
        var failed: [(name: String, reason: String)] = []
        var destinationError: String?
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            destinationError = error.localizedDescription
        }
        for name in arrival.names {
            let source = folder.appendingPathComponent(name)
            // Listed but never uploaded: nothing to lose.
            guard exists(source) else { continue }
            if let destinationError { failed.append((name, destinationError)); continue }
            var target = destination.appendingPathComponent(name)
            var n = 2
            while exists(target) { target = destination.appendingPathComponent(numbered(name, n)); n += 1 }
            do {
                try fm.moveItem(at: source, to: target)
                result.delivered.append(target)
            } catch {
                failed.append((name, error.localizedDescription))
            }
        }
        result.failures = failed.map { "\($0.name): \($0.reason)" }
        if failed.isEmpty {
            try? fm.removeItem(at: folder)
            try? fm.removeItem(at: manifest)
            return result
        }
        // Keep what did not arrive outside the inbox, which is emptied when the VM stops.
        var stillHere: [String] = []
        if let keepRoot, let keepFolder = uniqueFolder(in: keepRoot, named: arrival.id) {
            for (name, _) in failed {
                let source = folder.appendingPathComponent(name), target = keepFolder.appendingPathComponent(name)
                do {
                    try fm.moveItem(at: source, to: target)
                    result.kept.append(target)
                } catch {
                    stillHere.append(name)
                }
            }
            if result.kept.isEmpty {
                try? fm.removeItem(at: keepFolder)
            } else {
                let note = "Tandem could not put these files received from the virtual machine into \(destination.path):\n\n"
                    + result.failures.joined(separator: "\n") + "\n"
                try? Data(note.utf8).write(to: keepFolder.appendingPathComponent("Why these files are here.txt"))
            }
        } else {
            stillHere = failed.map(\.name)
        }
        if stillHere.isEmpty {
            try? fm.removeItem(at: folder)
        } else {
            result.leftInInbox = true
            try? Data((stillHere.joined(separator: "\n") + "\n").utf8).write(to: inbox.appendingPathComponent(arrival.id + ".failed"))
        }
        try? fm.removeItem(at: manifest)
        return result
    }

    /// Without following a link at the end (a dangling link is still a name in use).
    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func uniqueFolder(in root: URL, named name: String) -> URL? {
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: root, withIntermediateDirectories: true)) != nil else { return nil }
        var candidate = root.appendingPathComponent(name, isDirectory: true), n = 2
        while exists(candidate) { candidate = root.appendingPathComponent("\(name) \(n)", isDirectory: true); n += 1 }
        return (try? fm.createDirectory(at: candidate, withIntermediateDirectories: false)) != nil ? candidate : nil
    }
}
