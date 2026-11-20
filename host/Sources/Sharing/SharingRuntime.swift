import Foundation
import VMCore

/// Keeps a running VM's `SharingPolicy` current. One instance per running VM, owned by the process that
/// runs it (the app or `vmctl start`).
///
/// The policy has two sources, both files in the bundle: the profile in `config.json` and the temporary
/// grants in `run/temporary-sharing.json`. Anyone may change them (the settings panel, `vmctl sharing`,
/// `vmctl share`); this object notices within a second and hands the new policy to `onChange`, which is
/// where the owner makes it take effect. Temporary grants are cleared when the VM starts and when it stops.
public final class SharingRuntime: @unchecked Sendable {
    private let bundleURL: URL
    private let lock = NSLock()
    private var _policy: SharingPolicy
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "tandem.sharing-runtime")
    /// Grants given by the owner itself at start (`vmctl start --share`); they are written to the run file.
    private let initialGrants: TemporaryGrants
    /// Called on a private queue with the previous and the new policy, whenever they differ.
    public var onChange: (@Sendable (_ old: SharingPolicy, _ new: SharingPolicy) -> Void)?

    public init(bundle: VMBundle, initialGrants: TemporaryGrants = TemporaryGrants()) {
        bundleURL = bundle.url
        self.initialGrants = initialGrants
        _policy = SharingPolicy(bundle.config, temporary: initialGrants)
    }

    /// The policy in force now. Safe to read from any thread; enforcement points read it on every use.
    public var policy: SharingPolicy { lock.withLock { _policy } }

    /// Claims the VM, drops grants left over from an earlier run, and starts watching.
    public func start() {
        guard let bundle = try? VMBundle.load(from: bundleURL) else { return }
        TemporarySharingFile.clear(bundle)
        try? TemporarySharingFile.save(initialGrants, bundle)
        TemporarySharingFile.claim(bundle)
        lock.withLock { _policy = SharingPolicy(bundle.config, temporary: initialGrants) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.reload() }
        timer.resume()
        lock.withLock { self.timer = timer }
    }

    /// Reads both files now instead of at the next tick. Returns the policy in force afterwards.
    @discardableResult
    public func refresh() -> SharingPolicy {
        queue.sync { reload() }
        return policy
    }

    private func reload() {
        guard let bundle = try? VMBundle.load(from: bundleURL) else { return }
        let new = SharingPolicy(bundle.config, temporary: TemporarySharingFile.load(bundle))
        let old: SharingPolicy? = lock.withLock {
            guard _policy != new else { return nil }
            let old = _policy; _policy = new; return old
        }
        if let old { onChange?(old, new) }
    }

    /// Stops watching and ends every temporary grant.
    public func stop() {
        let timer: DispatchSourceTimer? = lock.withLock { let t = self.timer; self.timer = nil; return t }
        timer?.cancel()
        if let bundle = try? VMBundle.load(from: bundleURL) {
            TemporarySharingFile.release(bundle)
            lock.withLock { _policy = SharingPolicy(bundle.config) }
        }
    }
}

/// Changes to a VM's sharing that are the same whoever asks: the settings panel and `vmctl` both call these.
public enum SharingStore {
    /// Replaces the VM's stored profile.
    public static func setProfile(_ profile: SharingProfile, bundleURL: URL) throws {
        var bundle = try VMBundle.load(from: bundleURL)
        // Restricting a VM closes everything, access given until shutdown included.
        if profile == .restricted { TemporarySharingFile.clear(bundle) }
        guard bundle.config.sharing != profile else { return }
        bundle.config.sharing = profile
        try bundle.save()
    }

    /// Shares a Mac folder with the VM, for good or until it shuts down. Returns the folder as shared.
    @discardableResult
    public static func share(path: String, name: String? = nil, readOnly: Bool = false, temporary: Bool, bundleURL: URL) throws -> SharedFolder {
        var bundle = try VMBundle.load(from: bundleURL)
        let grants = TemporarySharingFile.load(bundle)
        let existing = SharingPolicy(bundle.config, temporary: grants).folders
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let same = existing.first(where: { $0.folder.hostPath == standardized }) {
            throw VMError("That folder is already shared with this virtual machine as “\(same.name)”.")
        }
        let folder = try SharingEdit.folder(path: path, name: name, readOnly: readOnly, taken: existing.map(\.name))
        if temporary {
            guard TemporarySharingFile.hasLiveOwner(bundle) else {
                throw VMError("Temporary access lasts until the virtual machine shuts down, so it can only be given while it is running.")
            }
            var updated = grants
            updated.folders.append(folder)
            try TemporarySharingFile.save(updated, bundle)
        } else {
            bundle.config.sharedFolders.append(folder)
            try bundle.save()
        }
        return folder
    }

    /// Stops sharing a folder, given by name or by path, whether it was shared for good or temporarily.
    /// Returns how many folders were removed.
    @discardableResult
    public static func unshare(_ key: String, bundleURL: URL) throws -> Int {
        var bundle = try VMBundle.load(from: bundleURL)
        var removed = SharingEdit.remove(key, from: &bundle.config.sharedFolders)
        if removed > 0 { try bundle.save() }
        var grants = TemporarySharingFile.load(bundle)
        let temporary = SharingEdit.remove(key, from: &grants.folders)
        if temporary > 0 { try TemporarySharingFile.save(grants, bundle) }
        removed += temporary
        return removed
    }

    /// Sets or clears the temporary clipboard and USB settings of a running VM.
    public static func setTemporary(clipboard: ClipboardSharing?? = nil, usb: Bool?? = nil, bundleURL: URL) throws {
        let bundle = try VMBundle.load(from: bundleURL)
        guard TemporarySharingFile.hasLiveOwner(bundle) else {
            throw VMError("Temporary access lasts until the virtual machine shuts down, so it can only be given while it is running.")
        }
        var grants = TemporarySharingFile.load(bundle)
        if let clipboard { grants.clipboard = clipboard }
        if let usb { grants.usb = usb }
        try TemporarySharingFile.save(grants, bundle)
    }
}
