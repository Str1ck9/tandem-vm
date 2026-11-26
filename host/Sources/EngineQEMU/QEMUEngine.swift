import Foundation
import VMCore
import GuestLink
import NetHelperClient

/// Runs Windows (and optionally Linux) guests as a supervised `qemu-system-aarch64` process,
/// one process per VM, with `swtpm` beside it for TPM 2.0.
@MainActor
public final class QEMUEngine: VMEngine {
    public let kind: EngineKind = .qemu
    public let lifecycle = LifecycleMachine()
    public var onGuestStream: (@Sendable (GuestStream) -> Void)?

    public let bundle: VMBundle
    public var displayMode: QEMUDisplayMode
    public private(set) var toolchain: QEMUToolchain?

    private var qemu: Process?
    /// The VM's process while it runs, for showing what it uses.
    public var processIdentifier: Int32? { qemu.flatMap { $0.isRunning ? $0.processIdentifier : nil } }
    private var swtpm: Process?
    private var qmp: QMPClient?
    private var guestStream: FDStream?
    private var paths: QEMURunPaths
    public private(set) var bundleLease: BundleLease?
    private var stopRequested = false
    /// Set by `prepareSnapshot`: whether the VM ran before, so `finishSnapshot` resumes only then.
    private var snapshotPause: SnapshotPause?
    /// Held while a bridged VM runs; closing it ends the bridge. Once the VM is up, `networkLive` owns it.
    private var bridge: BridgeLease?
    /// Applies network changes to the running VM and owns its bridge (NetworkLive.swift).
    var networkLive: NetworkLiveApplier?
    /// USB devices redirected through the root helper, by `HostUSBDevice.qemuID` (USBDevices.swift).
    var usbLeases: [String: USBLease] = [:]
    /// USB drives handed over as their raw disk (the helper's lease), by `qemuID`.
    var usbDisks: [String: DiskLease] = [:]

    /// Where the Mac serves this VM's shared folders, if it does. Set before `start()`.
    public var hostServicePort: Int?
    /// Loopback ports forwarded to guest ports for published services (guest port: Mac port). Set before `start()`.
    public var serviceBackends: [Int: Int] = [:]
    /// The devices this run was started with, and the tools disc it was given: a saved state only loads
    /// into a VM with the same devices, so `saveState` checks them against the configuration on disk.
    private var bootDevices: [String] = []
    private var bootToolsISO: URL?
    /// A shared-folder device was pulled out of the running VM (`detachSharedFolders`).
    var foldersDetached = false

    public init(bundle: VMBundle, displayMode: QEMUDisplayMode = .cocoa) {
        self.bundle = bundle
        self.displayMode = displayMode
        self.paths = QEMURunPaths.forVM(bundle.id)
    }

    /// Socket of the guest's screen while the VM runs in `.embedded` display mode.
    public var displaySocketPath: String? {
        // A 3D VM draws in QEMU's own window; it has no screen socket.
        displayMode == .embedded && qemu?.isRunning == true ? paths.display : nil
    }

    /// QEMU's control connection while the VM runs.
    var controlChannel: QMPClient? { qmp }

    public var qemuLogURL: URL { bundle.logsDirectory.appendingPathComponent("qemu.log") }
    public var processIdentifiers: [Int32] { [qemu, swtpm].compactMap { $0?.isRunning == true ? $0?.processIdentifier : nil } }

    // MARK: Preparation

    /// Creates anything the bundle is missing: qcow2 disks, the firmware variable store, working directories.
    public nonisolated static func prepare(bundle: VMBundle, toolchain: QEMUToolchain, paths: QEMURunPaths) throws {
        let fm = FileManager.default
        for dir in [bundle.logsDirectory, bundle.tpmDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Decided before the firmware variables are written, which marks a VM as started once.
        let creatable = bundle.config.disks.filter { bundle.mayCreateMissingDisk($0, fileManager: fm) }.map(\.file)
        if !fm.fileExists(atPath: bundle.efiVarsURL.path) {
            try fm.copyItem(at: toolchain.firmwareVarsTemplate, to: bundle.efiVarsURL)
        }
        for disk in bundle.config.disks {
            // A hand-edited or damaged config must not make Tandem create or open files outside the VM.
            let url = try DiskPathRules.containedURL(disk.file, in: bundle.url)
            if let backing = disk.backing {
                if let problem = backing.problem() { throw VMError("“\(bundle.config.name)” cannot start.", detail: problem) }
                guard fm.fileExists(atPath: url.path) else { throw VMError("Disk image is missing: \(url.path)") }
            }
            let marker = bundle.uninitializedMarker(disk)
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: marker) // made by someone else (an import, a template)
                continue
            }
            guard creatable.contains(disk.file) else {
                throw VMError("“\(bundle.config.name)” cannot start: its disk “\(disk.file)” is missing.",
                              detail: "\(url.path)\nTandem does not replace a missing disk with an empty one. Put the file back (for example from a backup or a snapshot), then start the VM again.")
            }
            switch disk.format {
            case .qcow2: try QEMUToolchain.run(toolchain.qemuImg, ["create", "-q", "-f", "qcow2", url.path, "\(disk.sizeGiB)G"])
            case .raw: try DiskImage.createSparseRaw(at: url, sizeGiB: disk.sizeGiB)
            }
            try? fm.removeItem(at: marker)
        }
        for media in bundle.config.removableMedia where !fm.fileExists(atPath: bundle.mediaURL(media).path) {
            throw VMError("“\(bundle.config.name)” cannot start: the disc image “\(bundle.mediaURL(media).lastPathComponent)” is missing.",
                          detail: "\(bundle.mediaURL(media).path)\nChoose it again, or remove it, under Configure > Hardware > CD/DVD.")
        }
    }

    /// Makes the run's socket folder afresh. Only for a caller holding the VM's lease: the folder is
    /// named for this VM alone, and the lease means no other run of it can be using the folder.
    public nonisolated static func prepareRunFolder(_ paths: QEMURunPaths, lease: BundleLease) throws {
        guard lease.isHeld else { throw VMError("Internal error: the VM's run folder was prepared without its lease.") }
        let fm = FileManager.default
        try? fm.removeItem(at: paths.directory)
        try fm.createDirectory(at: paths.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    // MARK: VMEngine

    public func start() async throws {
        guard lifecycle.transition(to: .starting) else {
            throw VMError("“\(bundle.config.name)” cannot start while \(lifecycle.state.rawValue).")
        }
        // The claim on the bundle for the whole run: another process or engine running this VM would share
        // its disks. A run that crashed left files behind, cleaned up under the same claim.
        do {
            bundleLease = try BundleLease.acquire(bundle, purpose: "running")
            try CrashRecovery.requireNotRunningElsewhere(bundle)
        } catch {
            bundleLease?.release(); bundleLease = nil
            lifecycle.transition(to: .error, error: error as? VMError)
            throw error
        }
        CrashRecovery.recover(bundle, holding: bundleLease)
        stopRequested = false
        do {
            let toolchain = try QEMUCommandBuilder.uses3D(bundle.config)
                ? QEMUToolchain.locate3D(windows: QEMUCommandBuilder.usesWindows3D(bundle.config)) : QEMUToolchain.locate()
            self.toolchain = toolchain
            try Self.prepare(bundle: bundle, toolchain: toolchain, paths: paths)
            if let bundleLease { try Self.prepareRunFolder(paths, lease: bundleLease) }
            // A missing tools disc must not stop a VM from starting.
            let tools = bundle.config.guestOS == .linux ? (try? GuestTools.linuxISO()) ?? nil : nil
            // Bridged only where the VM's sharing profile allows it; otherwise the builder uses the shared network.
            let network = SharingPolicy(bundle.config).enforced(bundle.config.network)
            if network.mode == .bridged { bridge = try Self.openBridge(network, peerPath: paths.network) }
            let saved = bundle.suspendStateURL
            let arguments = try QEMUCommandBuilder.arguments(bundle: bundle, toolchain: toolchain, paths: paths, display: displayMode,
                                                             guestToolsISO: tools, bridgeSocket: bridge?.helperSocketPath,
                                                             incoming: try saved.map(Self.incomingSource), hostServicePort: hostServicePort,
                                                             serviceBackends: serviceBackends)
            bootDevices = Self.devices(in: arguments)
            bootToolsISO = tools
            foldersDetached = false

            if QEMUCommandBuilder.needsTPM(bundle.config) { try await startSwtpm(toolchain) }
            try startQEMU(toolchain, arguments)

            let qmp = try await QMPClient.connect(path: paths.qmp, timeout: 15)
            qmp.onEvent = { [weak self] name, data in Task { @MainActor in self?.handle(event: name, data: data) } }
            self.qmp = qmp
            let bridgePeer = paths.network
            let live = NetworkLiveApplier(monitor: qmp, current: network, bridge: bridge, localSocket: bridgePeer,
                                          hostServicePort: { [weak self] in self?.hostServicePort },
                                          serviceBackends: { [weak self] in self?.serviceBackends ?? [:] },
                                          openBridge: { try Self.openBridge($0, peerPath: bridgePeer) })
            networkLive = live
            bridge = nil
            if !network.cableIsConnected { _ = await live.apply(network, policy: SharingPolicy(bundle.config)) }

            let fd = try await UnixSocket.connect(path: paths.guestLink, timeout: 5)
            let stream = FDStream(fileDescriptor: fd)
            guestStream = stream
            if let handler = onGuestStream { handler(stream) }

            guard qemu?.isRunning == true else { throw VMError("QEMU exited during start-up.", detail: logTail()) }
            if saved != nil {
                try await waitForIncoming(qmp)
                // The disk moves on from here, so the saved state no longer matches it.
                bundle.discardSuspendState()
            }
            startWatchdog()
            // Who runs this VM, so a crash of this process can be cleaned up after (CrashRecovery).
            bundle.writeRunRecord(RunRecord(childPIDs: processIdentifiers, runFolder: paths.directory.path))
            lifecycle.transition(to: .running)
        } catch {
            let wrapped = (error as? VMError) ?? VMError("“\(bundle.config.name)” failed to start.", detail: error.localizedDescription)
            let detailed = VMError(wrapped.message, detail: [wrapped.detail, qemu == nil ? nil : logTail()].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
            stopRequested = true
            killAll()
            bridge?.close(); bridge = nil
            networkLive?.shutdown(); networkLive = nil
            if qemu == nil {
                // Nothing will exit to clean up after this run, so give the claim up here. With QEMU started,
                // its exit does that once it is really gone.
                try? FileManager.default.removeItem(at: paths.directory)
                bundleLease?.release(); bundleLease = nil
            }
            lifecycle.transition(to: .error, error: detailed)
            throw detailed
        }
    }

    /// A Windows install disc waits five seconds for “Press any key to boot from CD or DVD” and gives up
    /// otherwise. Presses Return once a second for a while, so a new VM starts its installer unattended.
    public func pressKeyForInstallerBoot(seconds: Int = 8) async {
        for _ in 0..<seconds {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let qmp, lifecycle.state == .running else { return }
            _ = try? await qmp.execute("send-key", arguments: ["keys": [["type": "qcode", "data": "ret"]]])
        }
    }

    /// Asks the network helper for a bridge onto the configured interface (or its first one).
    nonisolated static func openBridge(_ network: NetworkConfig, peerPath: String) throws -> BridgeLease {
        guard NetHelper.isInstalled else {
            throw VMError("Bridged networking needs the Tandem network helper.", detail: "Install it once with: sudo scripts/install-net-helper.sh")
        }
        var interface = network.bridgedInterface
        if interface == nil { interface = try NetHelper.interfaces().first }
        guard let interface else { throw VMError("This Mac has no network interface that can be bridged.") }
        return try NetHelper.bridge(interface: interface, peerPath: peerPath)
    }

    // MARK: Suspend and resume
    //
    // QEMU's migration stream, written to a file instead of another host, is the saved state. zstd shrinks
    // it several times over and is used when installed; the file name records which form it has.

    nonisolated static var zstd: String? {
        BundledTools.locate("zstd", fallbacks: BundledTools.systemPaths("zstd"))?.path
    }
    nonisolated static func shellQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The `-incoming` source for a saved state file.
    nonisolated static func incomingSource(_ file: URL) throws -> String {
        guard file.pathExtension == "zst" else { return "file:\(file.path)" }
        guard let zstd else { throw VMError("The VM was suspended with zstd compression, and zstd is no longer installed.", detail: "Install it with: brew install zstd") }
        return "exec:\(shellQuoted(zstd)) -dc \(shellQuoted(file.path))"
    }

    /// After a start with `-incoming`: waits until the state is loaded and the VM runs.
    private func waitForIncoming(_ qmp: QMPClient) async throws {
        for _ in 0..<1200 {
            guard qemu?.isRunning == true else { throw VMError("The suspended VM could not be resumed.", detail: logTail()) }
            let status = (try? await qmp.execute("query-status"))?["status"] as? String
            if status == "running" { return }
            if status == "paused" || status == "postmigrate" { try await qmp.execute("cont"); return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw VMError("The suspended VM did not finish resuming.", detail: logTail())
    }

    /// Pauses the VM and writes its state into the bundle. The VM stays paused.
    /// The `-device` values of an argument list: what the guest's hardware consists of.
    static func devices(in arguments: [String]) -> [String] {
        zip(arguments, arguments.dropFirst()).filter { $0.0 == "-device" }.map(\.1)
    }

    /// A saved state is loaded into a VM built from the configuration on disk. If that would no longer
    /// have the devices this run has (a Mac folder was added or removed, or the network was cut down,
    /// while the VM ran), the state could never be loaded again, so saving it is refused.
    private func requireUnchangedDevices() throws {
        var changed = foldersDetached
        if !changed, let toolchain, let current = try? VMBundle.load(from: bundle.url),
           let arguments = try? QEMUCommandBuilder.arguments(bundle: current, toolchain: toolchain, paths: paths, display: displayMode,
                                                             guestToolsISO: bootToolsISO, bridgeSocket: networkLive?.bridge?.helperSocketPath ?? bridge?.helperSocketPath ?? "unused",
                                                             hostServicePort: hostServicePort, serviceBackends: serviceBackends) {
            changed = Self.devices(in: arguments) != bootDevices
        }
        if changed {
            throw VMError("“\(bundle.config.name)” cannot be suspended right now.",
                          detail: "Its shared folders or network settings changed while it was running, and they take effect when it starts. Shut it down and start it again; after that it can be suspended as usual.")
        }
    }

    private func saveState() async throws {
        guard let qmp, lifecycle.state == .running || lifecycle.state == .paused else { throw VMError("The VM is not running.") }
        try requireUnchangedDevices()
        let name = Self.zstd == nil ? VMBundle.suspendFileNames[0] : VMBundle.suspendFileNames[1]
        let target = bundle.url.appendingPathComponent(name)
        let partial = bundle.url.appendingPathComponent(".suspend.partial")
        try? FileManager.default.removeItem(at: partial)
        bundle.discardSuspendState()
        let wasRunning = lifecycle.state == .running
        if wasRunning { try await qmp.execute("stop") }
        do {
            // No point in pacing the copy: the VM is paused and the target is a local file.
            _ = try? await qmp.execute("migrate-set-parameters", arguments: ["max-bandwidth": 100_000_000_000])
            let uri = Self.zstd.map { "exec:\(Self.shellQuoted($0)) -1 -T0 -q -o \(Self.shellQuoted(partial.path))" } ?? "file:\(partial.path)"
            try await qmp.execute("migrate", arguments: ["uri": uri])
            var status = ""
            for _ in 0..<6000 {
                try await Task.sleep(nanoseconds: 100_000_000)
                let info = try await qmp.execute("query-migrate")
                status = info["status"] as? String ?? ""
                if status == "completed" { break }
                if status == "failed" || status == "cancelled" {
                    throw VMError("The VM's state could not be saved.", detail: info["error-desc"] as? String)
                }
            }
            guard status == "completed" else { throw VMError("Saving the VM's state took too long.") }
            try FileManager.default.moveItem(at: partial, to: target)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            // Leave the VM as it was found.
            _ = try? await qmp.execute("migrate_cancel")
            if wasRunning { _ = try? await qmp.execute("cont") }
            throw error
        }
    }

    public func suspend() async throws {
        try await saveState()
        stopRequested = true
        lifecycle.transition(to: .stopping)
        if let qmp { _ = try? await qmp.execute("quit") }
        for _ in 0..<100 where qemu?.isRunning == true { try? await Task.sleep(nanoseconds: 50_000_000) }
        killAll()
    }

    /// Restarts the guest without asking it, like a reset button.
    public func reset() async throws {
        guard let qmp, lifecycle.state == .running || lifecycle.state == .paused else { throw VMError("The VM is not running.") }
        try await qmp.execute("system_reset")
        if lifecycle.state == .paused { try await qmp.execute("cont"); lifecycle.transition(to: .running) }
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
        guard let qmp, pause?.resumeAfterwards ?? true else { return }
        try await qmp.execute("cont")
        if lifecycle.state == .paused { lifecycle.transition(to: .running) }
    }

    // MARK: Watchdog

    /// QEMU must not outlive the app. macOS has no "die with parent", so a small shell loop watches this
    /// process and ends QEMU and swtpm when it is gone, however it went.
    private func startWatchdog() {
        let pids = processIdentifiers
        guard !pids.isEmpty else { return }
        let targets = pids.map(String.init).joined(separator: " ")
        let script = "while kill -0 \(getpid()) 2>/dev/null; do kill -0 \(pids[0]) 2>/dev/null || exit 0; sleep 2; done; kill \(targets) 2>/dev/null; sleep 3; kill -9 \(targets) 2>/dev/null"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private func startSwtpm(_ toolchain: QEMUToolchain) async throws {
        guard let tool = toolchain.swtpm else {
            throw VMError("swtpm is not installed.", detail: "Windows 11 needs a TPM 2.0 device. Install it with: brew install swtpm")
        }
        // Paths with a comma reach swtpm through links in the run folder (its parser cannot take them).
        for (link, target) in QEMUCommandBuilder.swtpmLinks(bundle: bundle, paths: paths) {
            unlink(link)
            guard symlink(target, link) == 0 else {
                throw VMError("swtpm did not start.", detail: "Cannot link \(link) to \(target): \(String(cString: strerror(errno)))")
            }
        }
        let process = Process()
        process.executableURL = tool
        process.arguments = QEMUCommandBuilder.swtpmArguments(bundle: bundle, paths: paths)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        swtpm = process
        // QEMU connects at launch, so the control socket must exist first.
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: paths.tpm) {
            guard process.isRunning, Date() < deadline else {
                throw VMError("swtpm did not start.", detail: try? String(contentsOf: bundle.logsDirectory.appendingPathComponent("swtpm.log"), encoding: .utf8))
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func startQEMU(_ toolchain: QEMUToolchain, _ arguments: [String]) throws {
        FileManager.default.createFile(atPath: qemuLogURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: qemuLogURL)
        try log.write(contentsOf: Data("# \(toolchain.qemuVersion)\n# \(toolchain.qemu.path) \(arguments.joined(separator: " "))\n".utf8))
        let process = Process()
        process.executableURL = toolchain.qemu
        process.arguments = arguments
        process.currentDirectoryURL = bundle.url
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        if QEMUCommandBuilder.usesWindows3D(bundle.config) {
            // virglrenderer's Neptune path loads DXMT (Direct3D 11 on Metal) from this path. Apple's
            // D3DMetal is never used: its licence does not allow shipping it.
            let dxmt = QEMUToolchain.dxmtLibrary(in: QEMUToolchain.prefix(of: toolchain.qemu)).path
            var environment = ProcessInfo.processInfo.environment
            environment["NPT_BACKEND"] = "dxmt"
            environment["NPT_D3D11_LIBRARY_PATH"] = dxmt
            environment["NPT_DXGI_LIBRARY_PATH"] = dxmt
            // Direct3D runs in virglrenderer's render server, a separate process next to QEMU.
            environment["RENDER_SERVER_EXEC_PATH"] = QEMUToolchain.renderServer(in: QEMUToolchain.prefix(of: toolchain.qemu)).path
            process.environment = environment
        }
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus, reason = p.terminationReason
            Task { @MainActor in self?.qemuDidExit(status: status, reason: reason) }
        }
        try process.run()
        qemu = process
    }

    public func pause() async throws {
        guard let qmp, lifecycle.can(.pause) else { throw VMError("The VM is not running.") }
        try await qmp.execute("stop")
        lifecycle.transition(to: .paused)
    }

    public func resume() async throws {
        guard let qmp, lifecycle.can(.resume) else { throw VMError("The VM is not paused.") }
        try await qmp.execute("cont")
        lifecycle.transition(to: .running)
    }

    public func requestStop() async throws {
        guard let qmp, lifecycle.can(.stop) else { throw VMError("The VM is not running.") }
        if lifecycle.state == .paused { try await qmp.execute("cont"); lifecycle.transition(to: .running) }
        stopRequested = true
        lifecycle.transition(to: .stopping)
        try await qmp.execute("system_powerdown")
    }

    public func forceStop() async throws {
        guard lifecycle.can(.forceStop) else { return }
        stopRequested = true
        if lifecycle.state != .stopping { lifecycle.transition(to: .stopping) }
        if let qmp { _ = try? await qmp.execute("quit") }
        // Give QEMU a moment to exit by itself, then kill.
        for _ in 0..<40 where qemu?.isRunning == true { try? await Task.sleep(nanoseconds: 50_000_000) }
        killAll()
    }

    // MARK: Events and exit

    private func handle(event: String, data: [String: Any]) {
        switch event {
        case "STOP": if lifecycle.state == .running { lifecycle.transition(to: .paused) }
        case "RESUME": if lifecycle.state == .paused { lifecycle.transition(to: .running) }
        case "SHUTDOWN":
            // The guest powered off; QEMU exits by itself. A guest-initiated shutdown is a clean stop.
            stopRequested = true
        default: break
        }
    }

    private func qemuDidExit(status: Int32, reason: Process.TerminationReason) {
        guard qemu != nil else { return }
        let requested = stopRequested
        let tail = logTail()
        cleanup()
        if requested || (status == 0 && reason == .exit) {
            if !lifecycle.transition(to: .stopped) { lifecycle.transition(to: .stopping); lifecycle.transition(to: .stopped) }
        } else {
            let why = reason == .uncaughtSignal ? "killed by signal \(status)" : "exit code \(status)"
            lifecycle.transition(to: .error, error: VMError("QEMU stopped unexpectedly (\(why)).", detail: tail))
        }
    }

    private func killAll() {
        for process in [qemu, swtpm] {
            guard let process, process.isRunning else { continue }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func cleanup() {
        guestStream?.close(); guestStream = nil
        qmp?.close(); qmp = nil
        if let swtpm, swtpm.isRunning {
            // swtpm runs with --terminate and exits when QEMU disconnects; make sure of it.
            let pid = swtpm.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if swtpm.isRunning { kill(pid, SIGKILL) } }
        }
        qemu = nil; swtpm = nil
        bridge?.close(); bridge = nil
        networkLive?.shutdown(); networkLive = nil
        // The helper gives each device back to macOS when its lease ends.
        for lease in usbLeases.values { lease.close() }
        usbLeases = [:]
        // QEMU has exited, so nothing holds the disks any more: they go back to the Mac.
        let disks = Array(usbDisks.values)
        usbDisks = [:]
        if !disks.isEmpty { Task.detached { for disk in disks { disk.release() } } }
        // Only while this run still holds the lease is the folder certainly its own.
        if bundleLease?.isHeld == true { try? FileManager.default.removeItem(at: paths.directory) }
        bundle.clearRunRecord()
        bundleLease?.release(); bundleLease = nil
    }

    /// Last lines of QEMU's stderr, for error messages.
    public func logTail(lines: Int = 12) -> String {
        guard let text = try? String(contentsOf: qemuLogURL, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").filter { !$0.hasPrefix("#") }.suffix(lines).joined(separator: "\n")
    }
}
