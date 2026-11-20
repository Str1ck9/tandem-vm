import Foundation
import Virtualization
import VMCore
import GuestLink
import NetHelperClient

/// Runs macOS and Linux guests on Virtualization.framework.
@MainActor
public final class VZEngine: NSObject, VMEngine, VZVirtualMachineDelegate, VZVirtioSocketListenerDelegate {
    public let kind: EngineKind = .vz
    public let lifecycle = LifecycleMachine()
    public var onGuestStream: (@Sendable (GuestStream) -> Void)?

    public let bundle: VMBundle
    /// The running machine. The app hands this to a `VZVirtualMachineView`.
    public private(set) var virtualMachine: VZVirtualMachine?
    private var listener: VZVirtioSocketListener?
    private var configuration: VZVirtualMachineConfiguration?
    /// Held while a bridged VM runs; closing it ends the bridge.
    private var bridge: BridgeLease?
    private var bridgeSocketPath: String?
    /// Set by `prepareSnapshot`: whether the VM ran before, so `finishSnapshot` resumes only then.
    private var snapshotPause: SnapshotPause?
    public private(set) var bundleLease: BundleLease?

    private func releaseLease() { bundleLease?.release(); bundleLease = nil }

    public init(bundle: VMBundle) {
        self.bundle = bundle
    }

    public func start() async throws {
        guard lifecycle.transition(to: .starting) else {
            throw VMError("“\(bundle.config.name)” cannot start while \(lifecycle.state.rawValue).")
        }
        // The claim on the bundle for the whole run: no second engine, clone or revert meanwhile.
        do {
            let lease = try BundleLease.acquire(bundle, purpose: "running")
            bundleLease = lease
            try CrashRecovery.requireNotRunningElsewhere(bundle)
        } catch {
            releaseLease()
            lifecycle.transition(to: .error, error: error as? VMError)
            throw error
        }
        CrashRecovery.recover(bundle, holding: bundleLease)
        do {
            let configuration = try VZConfigurationBuilder.build(for: bundle, bridgeSocket: try openBridge())
            self.configuration = configuration
            let vm = VZVirtualMachine(configuration: configuration)
            vm.delegate = self
            virtualMachine = vm
            attachGuestListener(vm)
            if let saved = bundle.suspendStateURL {
                // Resume a suspended VM: load its saved state, which leaves it paused, then let it run.
                try await vm.restoreMachineStateFrom(url: saved)
                try await vm.resume()
                // The disk moves on from here, so the saved state no longer matches it.
                bundle.discardSuspendState()
            } else {
                do { try await vm.start() }
                catch where Self.isAuxiliaryStorageBusy(error) {
                    // Straight after a macOS install, Apple's installer can still hold the VM's auxiliary
                    // storage for a few seconds. Build the machine again and retry until it is free.
                    try await startAfterAuxiliaryStorageIsFree()
                }
            }
            bundle.writeRunRecord(RunRecord())
            lifecycle.transition(to: .running)
        } catch {
            virtualMachine = nil
            closeBridge()
            releaseLease()
            let wrapped = (error as? VMError) ?? VMError("“\(bundle.config.name)” failed to start.", detail: error.localizedDescription)
            lifecycle.transition(to: .error, error: wrapped)
            throw wrapped
        }
    }

    /// Virtualization.framework reports a locked auxiliary storage file (another VM object, usually the
    /// macOS installer that has just finished, still holds it).
    nonisolated static func isAuxiliaryStorageBusy(_ error: Error) -> Bool {
        let text = (error as NSError).localizedDescription.lowercased() + " " + String(describing: error).lowercased()
        return text.contains("auxiliary storage") && text.contains("lock")
    }

    /// Retries for up to about 20 seconds, with a fresh configuration and machine each time.
    private func startAfterAuxiliaryStorageIsFree() async throws {
        var lastError: Error?
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            do {
                let configuration = try VZConfigurationBuilder.build(for: bundle, bridgeSocket: try openBridge())
                self.configuration = configuration
                let vm = VZVirtualMachine(configuration: configuration)
                vm.delegate = self
                virtualMachine = vm
                attachGuestListener(vm)
                try await vm.start()
                return
            } catch where Self.isAuxiliaryStorageBusy(error) {
                closeBridge()
                lastError = error
            }
        }
        throw VMError("“\(bundle.config.name)” could not start: its macOS storage stayed locked.",
                      detail: "\(lastError.map { ($0 as NSError).localizedDescription } ?? "") Quit and reopen Tandem, then start it again.")
    }

    /// For a bridged VM: a bridge from the network helper and this VM's socket to it.
    private func openBridge() throws -> FileHandle? {
        // Bridged only where the VM's sharing profile allows it.
        let network = SharingPolicy(bundle.config).enforced(bundle.config.network)
        guard network.mode == .bridged else { return nil }
        guard NetHelper.isInstalled else {
            throw VMError("Bridged networking needs the Tandem network helper.", detail: "Install it once with: sudo scripts/install-net-helper.sh")
        }
        var interface = network.bridgedInterface
        if interface == nil { interface = try NetHelper.interfaces().first }
        guard let interface else { throw VMError("This Mac has no network interface that can be bridged.") }
        // The VM's full identifier, so no two VMs share it; the shorter form where the temporary directory's
        // path would take the socket past the 103 bytes unix socket paths hold.
        var path = NSTemporaryDirectory() + "tandem-net-\(RunFolder.hexDigits(bundle.id)).sock"
        if path.utf8.count > UnixSocket.maxPathLength { path = NSTemporaryDirectory() + "tandem-net-\(RunFolder.base32(bundle.id)).sock" }
        let lease = try NetHelper.bridge(interface: interface, peerPath: path)
        do {
            let fd = try NetHelper.makeClientSocket(at: path, connectedTo: lease.helperSocketPath)
            bridge = lease
            bridgeSocketPath = path
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        } catch {
            lease.close()
            throw error
        }
    }

    private func closeBridge() {
        bridge?.close(); bridge = nil
        if let path = bridgeSocketPath { unlink(path) }
        bridgeSocketPath = nil
    }

    /// Replaces the folders of the running VM's sharing device, so that a folder taken away is gone on
    /// the host side at once and a new one appears without a restart. Returns false when the VM has no
    /// such device (a macOS guest started with nothing shared).
    @discardableResult
    public func updateSharedFolders(_ folders: [SharedFolder]) throws -> Bool {
        guard let device = virtualMachine?.directorySharingDevices.first as? VZVirtioFileSystemDevice else { return false }
        device.share = try VZConfigurationBuilder.share(folders)
        return true
    }

    private func attachGuestListener(_ vm: VZVirtualMachine) {
        guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else { return }
        let listener = VZVirtioSocketListener()
        listener.delegate = self
        device.setSocketListener(listener, forPort: GuestLinkConstants.vsockPort)
        self.listener = listener
    }

    public func pause() async throws {
        guard let vm = virtualMachine, lifecycle.can(.pause) else { throw VMError("The VM is not running.") }
        try await vm.pause()
        lifecycle.transition(to: .paused)
    }

    public func resume() async throws {
        guard let vm = virtualMachine, lifecycle.can(.resume) else { throw VMError("The VM is not paused.") }
        try await vm.resume()
        lifecycle.transition(to: .running)
    }

    public func requestStop() async throws {
        guard let vm = virtualMachine, lifecycle.can(.stop) else { throw VMError("The VM is not running.") }
        if lifecycle.state == .paused { try await vm.resume(); lifecycle.transition(to: .running) }
        lifecycle.transition(to: .stopping)
        do { try vm.requestStop() }
        catch { throw VMError("The guest did not accept the stop request.", detail: error.localizedDescription) }
    }

    // MARK: Suspend and resume

    /// Pauses the VM and writes its state into the bundle. The VM stays paused.
    private func saveState() async throws {
        guard let vm = virtualMachine, lifecycle.state == .running || lifecycle.state == .paused else { throw VMError("The VM is not running.") }
        do { try configuration?.validateSaveRestoreSupport() }
        catch { throw VMError("This VM cannot be suspended.", detail: error.localizedDescription) }
        let target = bundle.url.appendingPathComponent(VMBundle.suspendFileNames[0])
        let partial = bundle.url.appendingPathComponent(".suspend.partial")
        try? FileManager.default.removeItem(at: partial)
        bundle.discardSuspendState()
        let wasRunning = lifecycle.state == .running
        if wasRunning { try await vm.pause() }
        do {
            try await vm.saveMachineStateTo(url: partial)
            try FileManager.default.moveItem(at: partial, to: target)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            if wasRunning { try? await vm.resume() }
            throw VMError("The VM's state could not be saved.", detail: error.localizedDescription)
        }
    }

    public func suspend() async throws {
        try await saveState()
        guard let vm = virtualMachine else { return }
        lifecycle.transition(to: .stopping)
        do { try await vm.stop() } catch { /* already stopped */ }
        finish(error: nil)
    }

    public func prepareSnapshot() async throws {
        let pause = SnapshotPause(stateBefore: lifecycle.state)
        try await saveState()
        snapshotPause = pause
        if lifecycle.state == .running { lifecycle.transition(to: .paused) }
    }

    public func finishSnapshot() async throws {
        bundle.discardSuspendState()
        let pause = snapshotPause
        snapshotPause = nil
        // A VM the user had paused stays paused.
        guard let vm = virtualMachine, pause?.resumeAfterwards ?? true else { return }
        try await vm.resume()
        if lifecycle.state == .paused { lifecycle.transition(to: .running) }
    }

    public func forceStop() async throws {
        guard let vm = virtualMachine, lifecycle.can(.forceStop) else { return }
        if lifecycle.state != .stopping { lifecycle.transition(to: .stopping) }
        do { try await vm.stop() } catch { /* already stopped */ }
        finish(error: nil)
    }

    private func finish(error: VMError?) {
        guard virtualMachine != nil else { return }
        virtualMachine = nil
        listener = nil
        closeBridge()
        bundle.clearRunRecord()
        releaseLease()
        if let error { lifecycle.transition(to: .error, error: error) }
        else { lifecycle.transition(to: .stopped) }
    }

    // MARK: VZVirtualMachineDelegate

    public nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in self.finish(error: nil) }
    }

    public nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.finish(error: VMError("The VM stopped unexpectedly.", detail: message)) }
    }

    // MARK: VZVirtioSocketListenerDelegate

    public nonisolated func listener(_ listener: VZVirtioSocketListener,
                                     shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                                     from socketDevice: VZVirtioSocketDevice) -> Bool {
        let stream = FDStream(fileDescriptor: connection.fileDescriptor, owner: connection)
        Task { @MainActor in
            if let handler = self.onGuestStream { handler(stream) } else { stream.close() }
        }
        return true
    }
}
