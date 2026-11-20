import EngineQEMU
import EngineVZ
import Foundation
import GuestLink
import Sharing
import VMCore

/// The policy in force, readable from any thread: the guest link asks it on every clipboard request.
final class SharingPolicyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var policy = SharingPolicy(profile: .default)
    var value: SharingPolicy {
        get { lock.withLock { policy } }
        set { lock.withLock { policy = newValue } }
    }
}

/// How a session keeps to its VM's sharing profile. Every change, whoever makes it (this app's settings
/// panel, `vmctl`), goes through the files in the bundle; `SharingRuntime` notices and `policyChanged`
/// makes it take effect, so there is one path however the change was asked for.
extension VMSession {
    /// Starts serving folders and watching for changes. A failure here must not stop the VM starting.
    func startSharing() {
        let runtime = SharingRuntime(bundle: bundle)
        runtime.onChange = { [weak self] old, new in
            Task { @MainActor in self?.policyChanged(from: old, to: new) }
        }
        runtime.start()
        sharingRuntime = runtime
        sharingNote = nil
        setPolicy(runtime.policy)
        do { try sharedFolders.start(config: config, policy: runtime.policy) }
        catch { errorMessage = "Shared folders are unavailable: \(error.localizedDescription)" }
        updateFileTransfers()
    }

    /// Ends every temporary grant with the VM.
    func stopSharing() {
        sharingRuntime?.stop()
        sharingRuntime = nil
        sharingNote = nil
        refreshSharingPolicy()
    }

    /// Takes the policy from the configuration again (and the running VM's temporary grants).
    func refreshSharingPolicy() {
        setPolicy(SharingPolicy(bundle.config, temporary: sharingRuntime?.policy.temporary ?? TemporaryGrants()))
    }

    private func setPolicy(_ policy: SharingPolicy) {
        sharingBox.value = policy
        if sharingPolicy != policy { sharingPolicy = policy }
        updateFileTransfers()
    }

    /// A change of policy while the VM runs. Taking access away happens here and now.
    private func policyChanged(from old: SharingPolicy, to new: SharingPolicy) {
        guard sharingRuntime != nil else { return }
        // The change may have been made by `vmctl`; keep this session's copy of the configuration in step,
        // so that a later save does not write the old profile back.
        if bundle.config.sharing != new.profile { bundle.config.sharing = new.profile }
        setPolicy(new)
        var notes: [String] = []
        // Folders. The VZ engine can swap the folders of its device; QEMU's WebDAV server takes a new list.
        var devicesUpdated = false
        if let vz = engine as? VZEngine, old.folders != new.folders {
            devicesUpdated = (try? vz.updateSharedFolders(new.folders.map(\.folder))) ?? false
        }
        let change = sharedFolders.apply(new, devicesUpdated: devicesUpdated)
        if change.announce { link.notifySharesChanged() }
        if let deferred = change.deferred { notes.append(deferred) }
        if !change.revokedDevices.isEmpty, let qemu = engine as? QEMUEngine {
            // Give the guest tools a moment to unmount, then pull the devices so nothing can mount them again.
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await qemu.detachSharedFolders(change.revokedDevices)
            }
        }
        // USB: devices the VM holds go back to the Mac.
        enforceUSBPolicy()
        // Clipboard needs nothing more: the link asks `sharingBox` on every request.
        // Connections in: taken away at once; everything else about the network waits for a restart.
        if old.allowsInboundServices && !new.allowsInboundServices { closeInboundPaths() }
        var laterNetwork = old.profile.network
        if !new.allowsInboundServices { laterNetwork.inbound = false }
        if laterNetwork != new.profile.network {
            notes.append("Network changes take effect when the virtual machine is restarted.")
        }
        sharingNote = notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    // MARK: Changes from the settings panel and menus

    /// Replaces the VM's sharing profile. Allowed while it runs: what can change live does, at once.
    func setSharing(_ profile: SharingProfile) throws {
        guard !isSuspended || state.isActive else {
            throw VMError("The virtual machine is suspended. Resume it to change what it shares.")
        }
        guard profile != bundle.config.sharing else { return }
        if state.isActive, let runtime = sharingRuntime {
            try SharingStore.setProfile(profile, bundleURL: bundle.url)
            runtime.refresh()
        } else {
            bundle.config.sharing = profile
            try bundle.save()
            refreshSharingPolicy()
        }
    }

    /// Shares a folder until the VM shuts down.
    func shareTemporarily(path: String, readOnly: Bool) throws {
        guard state.isActive, let runtime = sharingRuntime else {
            throw VMError("Temporary access lasts until the virtual machine shuts down, so it can only be given while it is running.")
        }
        guard sharedFolders.changesApplyLive || engine is VZEngine else {
            throw VMError("This virtual machine’s folders are attached when it starts, so a folder cannot be added while it runs.")
        }
        try SharingStore.share(path: path, readOnly: readOnly, temporary: true, bundleURL: bundle.url)
        runtime.refresh()
    }

    /// Stops sharing a folder (by name), whether shared for good or until shutdown.
    func unshare(_ name: String) throws {
        if state.isActive, let runtime = sharingRuntime {
            try SharingStore.unshare(name, bundleURL: bundle.url)
            runtime.refresh()
        } else {
            var profile = bundle.config.sharing
            SharingEdit.remove(name, from: &profile.folders)
            try setSharing(profile)
        }
    }
}
