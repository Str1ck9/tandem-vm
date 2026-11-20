import Foundation

/// A saved copy of a VM's state: its disks, firmware variables, TPM state and configuration.
public struct VMSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var created: Date
    public var note: String?
    /// The snapshot this one was taken on top of; nil for the first in a line.
    public var parent: UUID?
    /// False for snapshots written before parents were recorded; those are taken to follow one another by date.
    public var parentRecorded = true

    public init(id: UUID = UUID(), name: String, created: Date = Date(), note: String? = nil, parent: UUID? = nil) {
        self.id = id; self.name = name; self.created = created; self.note = note; self.parent = parent
    }

    enum CodingKeys: String, CodingKey { case id, name, created, note, parent }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        created = try c.decode(Date.self, forKey: .created)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        parentRecorded = c.contains(.parent)
        parent = try c.decodeIfPresent(UUID.self, forKey: .parent)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(created, forKey: .created)
        try c.encodeIfPresent(note, forKey: .note)
        // Always present, so that "no parent" can be told from "written before parents were recorded".
        if let parent { try c.encode(parent, forKey: .parent) } else { try c.encodeNil(forKey: .parent) }
    }
}

/// Snapshots of a stopped VM, kept inside its bundle under `snapshots/<id>/`.
///
/// A snapshot is a copy-on-write clone of every state file in the bundle. On APFS a clone is made
/// instantly and shares its blocks with the original, so a snapshot only costs the space of what
/// changes afterwards. The same code serves both engines because it works on files, not disk formats.
public struct SnapshotStore: Sendable {
    public let bundleURL: URL
    private static let infoFileName = "snapshot.json"
    /// Bundle entries that are not VM state.
    private static let excluded: Set<String> = ["snapshots", "logs", "run"]

    public init(bundle: VMBundle) { bundleURL = bundle.url }
    /// For a bundle whose config cannot be read yet (a revert cut off half-way may have moved it aside).
    public init(bundleURL: URL) { self.bundleURL = bundleURL }

    private var directory: URL { bundleURL.appendingPathComponent("snapshots", isDirectory: true) }
    private func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }
    private var headURL: URL { directory.appendingPathComponent("current.json") }
    private struct Head: Codable { var parent: UUID? }

    /// The picture of the guest's screen when the snapshot was taken, if there is one.
    public func thumbnailURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("thumbnail.png") }

    /// Every snapshot with the one it follows. Snapshots from before parents were recorded follow one another by date.
    public func parents(fileManager fm: FileManager = .default) -> [UUID: UUID?] {
        let oldestFirst = list(fileManager: fm).sorted { $0.created < $1.created }
        let known = Set(oldestFirst.map(\.id))
        var result: [UUID: UUID?] = [:]
        for (index, snapshot) in oldestFirst.enumerated() {
            if snapshot.parentRecorded { result[snapshot.id] = snapshot.parent.flatMap { known.contains($0) ? $0 : nil } }
            else { result[snapshot.id] = index > 0 ? oldestFirst[index - 1].id : nil }
        }
        return result
    }

    /// The snapshot the VM's current state descends from: the last one taken or gone back to.
    public func currentParent(fileManager fm: FileManager = .default) -> UUID? {
        let all = list(fileManager: fm)
        if let data = try? Data(contentsOf: headURL), let head = try? JSONDecoder().decode(Head.self, from: data) {
            return head.parent.flatMap { id in all.contains { $0.id == id } ? id : nil }
        }
        return all.first?.id // before this was recorded: the newest
    }

    private func setCurrentParent(_ id: UUID?, fileManager fm: FileManager) {
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Head(parent: id)).write(to: headURL, options: .atomic)
    }

    private func write(_ snapshot: VMSnapshot) throws {
        try ConfigCoding.encoder().encode(snapshot).write(to: folder(snapshot.id).appendingPathComponent(Self.infoFileName), options: .atomic)
    }

    /// Newest first.
    public func list(fileManager fm: FileManager = .default) -> [VMSnapshot] {
        let folders = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { url -> VMSnapshot? in
            guard let data = try? Data(contentsOf: url.appendingPathComponent(Self.infoFileName)) else { return nil }
            return try? ConfigCoding.decoder().decode(VMSnapshot.self, from: data)
        }
        .sorted { $0.created > $1.created }
    }

    /// Names of the bundle's state entries, hidden work folders left out.
    private func stateItems(in url: URL, fileManager fm: FileManager) throws -> [String] {
        try fm.contentsOfDirectory(atPath: url.path)
            .filter { !Self.excluded.contains($0) && !$0.hasPrefix(".") && $0 != Self.infoFileName }
            .sorted()
    }

    private func checkSelfContained(_ config: VMConfig) throws {
        if let outside = config.disks.first(where: { $0.file.hasPrefix("/") }) {
            throw VMError("This VM cannot be snapshotted: its disk is stored outside the VM, at \(outside.file).")
        }
    }

    @discardableResult
    public func create(name: String, note: String? = nil, config: VMConfig, fileManager fm: FileManager = .default) throws -> VMSnapshot {
        try checkSelfContained(config)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let cleanNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = VMSnapshot(name: trimmed.isEmpty ? "Snapshot" : trimmed, note: cleanNote?.isEmpty == false ? cleanNote : nil,
                                  parent: currentParent(fileManager: fm))
        let target = folder(snapshot.id)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        do {
            for item in try stateItems(in: bundleURL, fileManager: fm) {
                try Self.clone(bundleURL.appendingPathComponent(item), to: target.appendingPathComponent(item))
            }
            try write(snapshot)
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
        setCurrentParent(snapshot.id, fileManager: fm)
        return snapshot
    }

    /// True when the snapshot was taken while the VM ran, so going back to it resumes the VM where it was.
    public func includesRunningState(_ id: UUID) -> Bool {
        VMBundle.suspendFileNames.contains { FileManager.default.fileExists(atPath: folder(id).appendingPathComponent($0).path) }
    }

    /// Copies a snapshot item into place. Replaceable so tests can make a copy fail part-way.
    public typealias Copier = (_ source: URL, _ destination: URL) throws -> Void

    /// What a revert in progress has done, written into the bundle before anything is moved, so that a
    /// revert cut off by a crash or power cut can be put right (or at least found) later.
    struct RevertJournal: Codable, Equatable {
        /// staging: copying the snapshot beside the VM. movingAside: the VM's files are going into `aside`,
        /// nothing of the snapshot is in the bundle yet. placing: all the VM's files are aside, so every
        /// state item in the bundle is a snapshot copy.
        enum Phase: String, Codable { case staging, movingAside, placing }
        var snapshot: UUID
        /// Snapshot copies being prepared, inside the bundle.
        var staging: String
        /// Where the VM's own files are moved while the snapshot's go in.
        var aside: String
        var phase: Phase
        /// The process doing the revert; recovery leaves a live one alone.
        var pid: Int32
    }

    static let journalName = ".revert-journal.json"
    private var journalURL: URL { bundleURL.appendingPathComponent(Self.journalName) }

    private func writeJournal(_ journal: RevertJournal) throws {
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
    }

    /// Puts the VM back to the snapshot. The snapshot is copied in full beside the VM's files first; only
    /// then are the VM's files moved aside and the copies moved in, which on one volume are renames. If
    /// anything fails the VM's own files are put back. They are deleted only once the snapshot's files
    /// are all in place, and kept (with the error saying where) whenever putting them back failed.
    public func revert(to id: UUID, fileManager fm: FileManager = .default, copy: Copier = SnapshotStore.cloneItem) throws {
        let source = folder(id)
        guard fm.fileExists(atPath: source.appendingPathComponent(VMBundle.configFileName).path) else {
            throw VMError("That snapshot is missing or incomplete.")
        }
        // An earlier revert that was cut off must be dealt with first, or its files would be mixed with these.
        if let leftover = try recoverInterruptedRevert(fileManager: fm), leftover.kept {
            throw VMError("An earlier return to a snapshot did not finish, and its files need checking first.", detail: leftover.message)
        }
        let token = UUID().uuidString.prefix(8).lowercased()
        let staging = bundleURL.appendingPathComponent(".revert-staging-\(token)", isDirectory: true)
        let aside = bundleURL.appendingPathComponent(".reverting-\(token)", isDirectory: true)
        var journal = RevertJournal(snapshot: id, staging: staging.lastPathComponent, aside: aside.lastPathComponent,
                                    phase: .staging, pid: getpid())
        try writeJournal(journal)

        // 1. The complete replacement, beside the VM. Nothing of the VM is touched yet.
        let incoming: [String]
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            incoming = try stateItems(in: source, fileManager: fm)
            for item in incoming { try copy(source.appendingPathComponent(item), staging.appendingPathComponent(item)) }
        } catch {
            try? fm.removeItem(at: staging) // only copies of the snapshot, partial ones included
            try? fm.removeItem(at: journalURL)
            throw error
        }

        // 2. Swap: the VM's files aside, the copies in.
        journal.phase = .movingAside
        let current: [String]
        do {
            try writeJournal(journal)
            current = try stateItems(in: bundleURL, fileManager: fm)
            try fm.createDirectory(at: aside, withIntermediateDirectories: true)
        } catch {
            try? fm.removeItem(at: aside); try? fm.removeItem(at: staging); try? fm.removeItem(at: journalURL)
            throw error
        }
        do {
            for item in current { try fm.moveItem(at: bundleURL.appendingPathComponent(item), to: aside.appendingPathComponent(item)) }
            journal.phase = .placing
            try writeJournal(journal)
            for item in incoming { try fm.moveItem(at: staging.appendingPathComponent(item), to: bundleURL.appendingPathComponent(item)) }
        } catch {
            if rollBack(aside: aside, staging: staging, snapshotItemsInBundle: journal.phase == .placing, fileManager: fm) {
                try? fm.removeItem(at: aside); try? fm.removeItem(at: staging); try? fm.removeItem(at: journalURL)
                throw error
            }
            throw VMError("Going back to the snapshot failed, and the VM's own files could not all be put back.",
                          detail: "\(error.localizedDescription)\nNothing was deleted. The VM's files are in \(aside.path); the snapshot's copies are in \(staging.path). Tandem tries again to put them back the next time it opens this VM.")
        }

        // 3. Done: the old state can go.
        try? fm.removeItem(at: journalURL)
        try? fm.removeItem(at: aside)
        try? fm.removeItem(at: staging)
        setCurrentParent(id, fileManager: fm)
    }

    /// Moves every file from `aside` back into the bundle. With `snapshotItemsInBundle` (the placing phase,
    /// when all of the VM's own files had gone aside) every state item in the bundle is a snapshot copy, and
    /// is first moved back to `staging`. True when `aside` ended up empty, so the VM is whole again.
    private func rollBack(aside: URL, staging: URL, snapshotItemsInBundle: Bool, fileManager fm: FileManager) -> Bool {
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        for item in snapshotItemsInBundle ? ((try? stateItems(in: bundleURL, fileManager: fm)) ?? []) : [] {
            let parked = staging.appendingPathComponent(item)
            if fm.fileExists(atPath: parked.path) { try? fm.removeItem(at: parked) }
            try? fm.moveItem(at: bundleURL.appendingPathComponent(item), to: parked)
        }
        for item in (try? fm.contentsOfDirectory(atPath: aside.path)) ?? [] {
            let target = bundleURL.appendingPathComponent(item)
            guard !fm.fileExists(atPath: target.path) else { continue }
            try? fm.moveItem(at: aside.appendingPathComponent(item), to: target)
        }
        guard let left = try? fm.contentsOfDirectory(atPath: aside.path) else { return false }
        return left.isEmpty
    }

    /// The result of looking for a revert that was cut off.
    public struct RevertRecovery: Equatable, Sendable {
        /// True when files were kept because they could not be put back (or a revert is still running);
        /// `message` says where they are.
        public var kept: Bool
        public var message: String
    }

    /// Deals with a revert that a crash or power cut interrupted: one still copying is abandoned; one that
    /// was swapping files is rolled back, so the VM is as it was before. Nil when there was nothing to do.
    @discardableResult
    public func recoverInterruptedRevert(fileManager fm: FileManager = .default) throws -> RevertRecovery? {
        guard let data = try? Data(contentsOf: journalURL) else { return nil }
        guard let journal = try? JSONDecoder().decode(RevertJournal.self, from: data),
              !journal.staging.contains("/"), !journal.aside.contains("/"),
              journal.staging.hasPrefix(".revert-staging-"), journal.aside.hasPrefix(".reverting-") else {
            return RevertRecovery(kept: true, message: "The record of an unfinished return to a snapshot in \(bundleURL.path) cannot be read. Nothing was changed; its files are in the bundle's hidden folders.")
        }
        if journal.pid != getpid(), kill(journal.pid, 0) == 0 || errno == EPERM {
            // Possibly still running elsewhere (another Tandem, or vmctl): waiting is harmless, rolling back under it is not.
            return RevertRecovery(kept: true, message: "Another program (process \(journal.pid)) is still returning this VM to a snapshot.")
        }
        let staging = bundleURL.appendingPathComponent(journal.staging)
        let aside = bundleURL.appendingPathComponent(journal.aside)
        let abandoned = RevertRecovery(kept: false, message: "An unfinished return to a snapshot was abandoned; the VM was not changed.")
        if journal.phase == .staging || !fm.fileExists(atPath: aside.path) {
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: journalURL)
            return abandoned
        }
        if rollBack(aside: aside, staging: staging, snapshotItemsInBundle: journal.phase == .placing, fileManager: fm) {
            try? fm.removeItem(at: aside); try? fm.removeItem(at: staging); try? fm.removeItem(at: journalURL)
            return RevertRecovery(kept: false, message: "A return to a snapshot was cut off; the VM was put back as it was before.")
        }
        return RevertRecovery(kept: true, message: "A return to a snapshot was cut off and the VM's files could not all be put back. Nothing was deleted: the VM's files are in \(aside.path).")
    }

    /// Changes a snapshot's name and description.
    public func rename(_ id: UUID, name: String, note: String?, fileManager fm: FileManager = .default) throws {
        guard var snapshot = list(fileManager: fm).first(where: { $0.id == id }) else { throw VMError("That snapshot no longer exists.") }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { snapshot.name = trimmed }
        let cleanNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        snapshot.note = cleanNote?.isEmpty == false ? cleanNote : nil
        snapshot.parent = parents(fileManager: fm)[id] ?? nil
        snapshot.parentRecorded = true
        try write(snapshot)
    }

    /// Deletes a snapshot. What followed it now follows what it followed.
    public func delete(_ id: UUID, fileManager fm: FileManager = .default) throws {
        let links = parents(fileManager: fm)
        let above = links[id] ?? nil
        let head = currentParent(fileManager: fm)
        // Record every remaining snapshot's parent explicitly: deleting one changes what "previous by date" means.
        for var snapshot in list(fileManager: fm) where snapshot.id != id {
            let parent = links[snapshot.id] ?? nil
            snapshot.parent = parent == id ? above : parent
            snapshot.parentRecorded = true
            try write(snapshot)
        }
        try fm.removeItem(at: folder(id))
        setCurrentParent(head == id ? above : head, fileManager: fm)
    }

    /// How big a snapshot is. `total` is what its files hold; `exclusive` is the space only this snapshot
    /// occupies, which is what deleting it would free. Right after a snapshot is taken `exclusive` is near
    /// zero, because its blocks are still shared with the running disk.
    public func size(of id: UUID, fileManager fm: FileManager = .default) -> (total: Int64, exclusive: Int64) {
        var total: Int64 = 0, exclusive: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let files = fm.enumerator(at: folder(id), includingPropertiesForKeys: keys) else { return (0, 0) }
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let allocated = Int64(values.totalFileAllocatedSize ?? 0)
            total += allocated
            exclusive += Self.privateSize(file) ?? allocated
        }
        return (total, exclusive)
    }

    /// Bytes of a file that no other file shares (APFS clones share blocks). Nil if the file system cannot say.
    static func privateSize(_ url: URL) -> Int64? {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        // Reply layout: u32 length, then the off_t value.
        var buffer = [UInt8](repeating: 0, count: 12)
        guard getattrlist(url.path, &attributes, &buffer, buffer.count, UInt32(FSOPT_ATTR_CMN_EXTENDED)) == 0 else { return nil }
        return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
    }

    /// Copy-on-write clone where the file system supports it, an ordinary copy elsewhere.
    public static func cloneItem(_ source: URL, _ destination: URL) throws { try clone(source, to: destination) }

    static func clone(_ source: URL, to destination: URL) throws {
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE)
        guard copyfile(source.path, destination.path, nil, flags) == 0 else {
            throw VMError("Cannot copy \(source.lastPathComponent).", detail: String(cString: strerror(errno)))
        }
    }
}
