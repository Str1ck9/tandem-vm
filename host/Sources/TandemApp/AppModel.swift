import AppKit
import Combine
import EngineQEMU
import EngineVZ
import GuestLink
import Provisioning
import SwiftUI
import VMCore
import Sharing
import Virtualization

/// Host clipboard for the guest link. Remembers what it wrote so its own writes are not sent back.
final class PasteboardBridge: ClipboardProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var lastSeenChangeCount = NSPasteboard.general.changeCount

    func text() -> String? { NSPasteboard.general.string(forType: .string) }

    func setText(_ text: String) {
        lock.withLock {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            lastSeenChangeCount = pasteboard.changeCount
        }
    }

    /// New text copied on the Mac since the last call, if any.
    func pollForChange() -> String? {
        lock.withLock {
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount != lastSeenChangeCount else { return nil }
            lastSeenChangeCount = pasteboard.changeCount
            return pasteboard.string(forType: .string)
        }
    }
}

/// One VM in the library together with its running engine, if any.
@MainActor
final class VMSession: ObservableObject, Identifiable {
    nonisolated let id: UUID
    @Published var bundle: VMBundle
    @Published private(set) var state: VMState = .stopped
    @Published var errorMessage: String? {
        // In Seamless Mode the VM window is closed, so a problem reported meanwhile gets an alert.
        didSet { if let message = errorMessage, message != oldValue, isSeamless { RuntimeErrorBanner.alert(message, vm: config.name) } }
    }
    /// True while the VM is stopped with its memory saved; the next start resumes it.
    @Published private(set) var isSuspended = false
    /// What a long operation is doing, shown in place of the state ("Suspending…").
    @Published var busy: String?
    @Published private(set) var agent: LinkSession.Hello?
    @Published private(set) var guestInfo: GuestInfo?
    @Published private(set) var displayReport: DisplayReport?
    /// Set while a VZ guest runs; the VM window shows it.
    @Published private(set) var virtualMachine: VZVirtualMachine?
    /// Set while a QEMU guest runs; the VM window draws it.
    @Published private(set) var screen: RFBClient?
    /// The last picture of the VM's screen, kept in the bundle so it survives a restart of the app.
    @Published private(set) var thumbnail: NSImage?
    private var thumbnailTask: Task<Void, Never>?

    let link = GuestLinkHost()
    var engine: (any VMEngine)?
    private nonisolated let guestLogURL: URL
    private let pasteboard: ClipboardProvider
    let sharedFolders = SharedFolderService()
    // What this VM shares with the Mac right now; kept current by SessionSharing.swift.
    @Published var sharingPolicy: SharingPolicy
    /// What a change of sharing could not do until the VM is restarted, for the settings panel.
    @Published var sharingNote: String?
    /// What the last network change did to this running VM (SessionNetwork.swift).
    @Published var networkApplyResult: NetworkApplyResult?
    var sharingRuntime: SharingRuntime?
    let sharingBox = SharingPolicyBox()
    /// Guest services published on the Mac while this VM runs (Sharing/ServicePublisher).
    private let publisher = ServicePublisher(statusDirectory: ServicePublisher.statusDirectory(
        inLibraryRoot: ProcessInfo.processInfo.environment["TANDEM_HOME"].map { URL(fileURLWithPath: $0) } ?? VMLibrary.defaultRoot()))
    /// Each published service and whether the Mac is listening for it; empty while the VM is stopped.
    @Published private(set) var serviceStatuses: [ServicePublisher.Status] = []

    init(bundle: VMBundle, clipboard: ClipboardProvider) {
        self.id = bundle.id
        self.guestLogURL = bundle.logsDirectory.appendingPathComponent("guest-agent.log")
        self.bundle = bundle
        self.isSuspended = bundle.isSuspended
        // A marker with no download running (a new session has none) is a setup that was cut short.
        self.setupInterrupted = SystemCatalog.marker(in: bundle) != nil
        self.pasteboard = clipboard
        self.sharingPolicy = SharingPolicy(bundle.config)
        sharingBox.value = SharingPolicy(bundle.config)
        // The provider is always there; the policy decides on every use which way text may go.
        link.clipboard = clipboard
        link.clipboardPolicy = { [sharingBox] in sharingBox.value.clipboard }
        thumbnail = NSImage(contentsOf: bundle.url.appendingPathComponent("thumbnail.png"))
        link.agentBinary = { os in
            switch os {
            case .windows: GuestTools.windowsAgent
            case .linux: GuestTools.linuxAgent
            case .macos: GuestTools.macOSAgent
            case nil: nil
            }
        }
        link.shares = { [sharedFolders] in SharesInfo(kind: sharedFolders.kind, port: sharedFolders.port, shares: sharedFolders.announcedNames) }
        link.onHello = { [weak self] hello in Task { @MainActor in self?.agentConnected(hello) } }
        link.onGuestInfo = { [weak self] info in
            Task { @MainActor in
                self?.guestInfo = info
                self?.sharedFolders.setGuestUTCOffset(info.utcOffsetSeconds)
            }
        }
        link.onDisplayReport = { [weak self] report in
            Task { @MainActor in
                self?.displayReport = report
                self?.applyConfiguredDisplaySizeIfNeeded(report)
                self?.adjustGuestScale()
            }
        }
        link.onDisconnect = { [weak self] in Task { @MainActor in self?.agent = nil; self?.exitSeamless(); self?.forgetIconRequests() } }
        link.onProgramList = { [weak self] programs in Task { @MainActor in self?.programsArrived(programs) } }
        link.onIcon = { [weak self] icon in Task { @MainActor in self?.iconArrived(icon) } }
        link.onProgramInfo = { [launches] info, logo in launches.programInfoArrived(info, logo: logo) }
        link.onDocumentResult = { [launches] result in launches.documentResultArrived(result) }
        link.onActivity = { [weak self] activity in Task { @MainActor in self?.guestActivityArrived(activity) } }
        refreshMacLaunchers()
        link.onLog = { [weak self] level, message in self?.appendGuestLog(level: level, message: message) }
    }

    var config: VMConfig { bundle.config }
    var isQEMU: Bool { config.engine == .qemu }
    var hasDisplayInApp: Bool { true }

    func can(_ action: VMAction) -> Bool { busy == nil && provisioning == nil && !setupInterrupted && action.validFrom.contains(state) }

    // Downloaded systems (ProvisioningJobs.swift): while Tandem fetches and prepares the system, the VM
    // exists but cannot be started.
    /// Where the download and preparation of this VM's system stand; nil when none is under way.
    @Published var provisioning: ProvisioningProgress?
    /// Stops the download and removes the half-made VM. Set while `provisioning` is.
    var cancelProvisioning: (() -> Void)?
    /// A download that never finished (Tandem quit, or the Mac restarted): the VM can only be removed.
    @Published var setupInterrupted = false

    /// The state as shown to the user.
    var statusLabel: String {
        if let provisioning {
            return provisioning.phase + (provisioning.fraction.map { " \(Int(($0 * 100).rounded(.down)))%" } ?? "…")
        }
        if setupInterrupted { return String(localized: "Setup did not finish") }
        if let busy { return busy }
        if let launchStatus { return launchStatus }
        if isInstalling { return "Installing \(config.guestOS.label)…" }
        return (state == .stopped && isSuspended) ? String(localized: "Suspended") : state.label
    }
    /// An unattended install is under way: Setup is running and the guest tools have not answered yet.
    var isInstalling: Bool { state == .running && config.install.unattended && config.install.state == .installing }
    /// Not with 3D acceleration: virglrenderer's GPU state cannot be saved, so QEMU refuses to migrate it.
    var canSuspend: Bool { busy == nil && (state == .running || state == .paused) && !QEMUCommandBuilder.uses3D(config) }
    var canReset: Bool { busy == nil && engine is QEMUEngine && (state == .running || state == .paused) }
    /// The configuration cannot change while the VM runs, or while saved memory expects the same hardware.
    var isLocked: Bool { state.isActive || isSuspended }
    private func refreshSuspended() { isSuspended = bundle.isSuspended }

    /// True while the VM is shut down and started again by Tandem itself; its window stays open meanwhile.
    @Published private(set) var isRestarting = false

    /// The last step of an unattended install. Windows was installed on the plain display device; the
    /// faster, resizable one and the detached install discs only apply from the next start. Without
    /// this restart a new VM looks as if its drivers were missing.
    private func finishInstallByRestarting() {
        guard state == .running, engine is QEMUEngine else { return }
        busy = "Finishing installation…"
        isRestarting = true
        Task { [weak self] in
            // Let the first-logon script and the agent's own update settle before shutting down.
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, self.isRestarting, self.state == .running, let engine = self.engine else { self?.endRestart(); return }
            self.link.requestGuestShutdown()
            do { try await engine.requestStop() } catch { self.endRestart() }
            // A guest that will not shut down is left running; the user can restart it later.
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            if self.isRestarting, self.state != .stopped { self.endRestart() }
        }
    }

    private func endRestart() { isRestarting = false; busy = nil }

    private func agentConnected(_ hello: LinkSession.Hello) {
        defer { behaviorAgentConnected() }
        agent = hello
        configuredSizeRequested = false
        resetCloneIdentityIfNeeded(capabilities: hello.capabilities)
        // The guest tools answering is the sign that an unattended install has reached the desktop.
        // Only Windows needs the restart that follows: its display driver applies from the next start.
        if InstallProgress.markComplete(&bundle), config.guestOS == .windows11arm { finishInstallByRestarting() }
        // Guest tools that know the guest's programs: ask for the list now, so the menus have it.
        if hello.capabilities & 128 != 0 { link.requestPrograms() }
        if busy?.hasPrefix("Restarting Windows") == true { busy = nil }
        installWindows3DDriverIfNeeded(capabilities: hello.capabilities)
        removeWindows3DDriverIfOff(capabilities: hello.capabilities)
        // A request for the macOS tools disc stays: it is settled at the next cold start.
        bundle.config.guestTools.installedVersion = hello.agentVersion
        bundle.config.guestTools.lastSeen = Date()
        try? bundle.save()
    }

    /// Guest agent log lines go to `logs/guest-agent.log` in the bundle.
    nonisolated func appendGuestLog(level: UInt32, message: String) {
        let names = ["debug", "info", "warn", "error"]
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(names[Int(min(level, 3))])] \(message)\n"
        let url = guestLogURL
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
    // MARK: Actions

    func start() {
        guard can(.start) else { return }
        errorMessage = nil
        // Windows with 3D on and no driver yet: fetch the driver disc first, then start (SessionWindows3D).
        if needsWindows3DDriverDisc { prepareWindows3DDriverThenStart(); return }
        // macOS: the tools disc stays attached until the tools have answered (GuestToolsMacOS.swift).
        if config.guestOS == .macos, GuestTools.settleMacOSDiscRequest(&bundle.config.guestTools, resuming: bundle.isSuspended) {
            try? bundle.save()
        }
        let engine: any VMEngine = config.engine == .vz ? VZEngine(bundle: bundle) : QEMUEngine(bundle: bundle, displayMode: .embedded)
        self.engine = engine
        // Shared folders are served for as long as the VM runs. A failure here must not stop the VM starting.
        // Only to this VM's QEMU (and the `nc` it runs per connection), not to other processes on the Mac.
        sharedFolders.onlyVMProcess = true
        startSharing()
        (engine as? QEMUEngine)?.hostServicePort = sharedFolders.port
        // Published services listen from now until the VM stops; a port that cannot be had is shown, not fatal.
        if !(config.publishedServices ?? []).isEmpty {
            let backends = ServicePublisher.needsBackends(config) ? ServicePublisher.backendPorts(for: config.publishedServices ?? []) : [:]
            (engine as? QEMUEngine)?.serviceBackends = backends
            LocalNames.startResponder()
            serviceStatuses = publisher.start(config: config, target: ServicePublisher.target(config: config, backends: backends) { [link] in link.guestInfo?.ipAddresses })
        }
        engine.onGuestStream = { [link] stream in link.attach(stream) }
        engine.lifecycle.onChange = { [weak self, weak engine] newState in
            Task { @MainActor in
                guard let self, let engine, self.engine === engine else { return }
                self.stateChanged(newState)
            }
        }
        let resuming = bundle.isSuspended
        Task {
            do {
                try await engine.start()
                sharedFolders.setVMProcess((engine as? QEMUEngine)?.processIdentifier)
                refreshSuspended()
                // A new VM with an install disc: get past the disc's "press any key" prompt.
                if InstallProgress.needsInstallerBoot(bundle.config), let qemu = engine as? QEMUEngine {
                    InstallProgress.markStarted(&bundle)
                    Task { await qemu.pressKeyForInstallerBoot() }
                }
                if resuming {
                    // The guest slept through the gap: put its clock right and hand the folders back.
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        self?.link.requestTimeResync()
                        self?.link.notifySharesChanged()
                    }
                }
                virtualMachine = (engine as? VZEngine)?.virtualMachine
                if let path = (engine as? QEMUEngine)?.displaySocketPath { await connectScreen(path) }
            } catch {
                errorMessage = error.userFacingText
            }
        }
    }

    private func connectScreen(_ path: String) async {
        do {
            let client = try await RFBClient.connect(path: path, timeout: 10)
            client.onClose = { [weak self, weak client] reason in
                Task { @MainActor in
                    guard let self, self.screen === client else { return }
                    self.exitSeamless()
                    self.screen = nil
                    // QEMU closes the display just before it exits, so a close during shutdown is normal.
                    // Only report it if the VM is still running a moment later.
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if let reason, self.state == .running || self.state == .paused {
                        self.errorMessage = "The display connection ended: \(reason)"
                    }
                }
            }
            client.inputSettings = GuestInputSettings(config.behaviorOrDefault)
            client.start()
            screen = client
            thumbnailTask?.cancel()
            thumbnailTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                while !Task.isCancelled, let self, self.screen === client {
                    self.captureThumbnail()
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                }
            }
        } catch {
            errorMessage = "The VM is running, but its display could not be opened.\n\(error.localizedDescription)"
        }
    }

    private func stateChanged(_ newState: VMState) {
        let previous = state
        defer { behaviorStateChanged(from: previous) }
        state = newState
        // The hidden transfer shares (drops from the Mac, files sent to the Mac) are set up for a running
        // VM; sharing starts while the VM is still stopped, so they are set up again once it runs.
        if newState == .running || newState == .stopped || newState == .error { updateFileTransfers() }
        // Started or resumed from its saved state: the idle timer begins again.
        if newState == .running, previous != .paused {
            powerState.reset()
            powerState.suspendedWhenIdle = nil
        }
        switch newState {
        case .error:
            errorMessage = engine?.lifecycle.lastError?.userFacingText ?? "The VM stopped with an error."
            fallthrough
        case .stopped:
            exitSeamless(reopenWindow: false)
            launches.cancelAll()
            guestPrograms = []
            guestIcons = [:]
            forgetIconRequests()
            virtualMachine = nil
            screen?.close()
            screen = nil
            agent = nil
            guestInfo = nil
            link.detach()
            sharedFolders.stop()
            publisher.stop()
            serviceStatuses = []
            stopSharing()
            usbAttached = []
            refreshSuspended()
            if isRestarting, newState == .stopped {
                // Second half of a restart Tandem asked for: start again once this stop has been processed.
                endRestart()
                DispatchQueue.main.async { [weak self] in self?.start() }
            } else if isRestarting {
                endRestart()
            }
        default: break
        }
    }

    private func perform(_ work: @escaping (any VMEngine) async throws -> Void) {
        guard let engine else { return }
        Task {
            do { try await work(engine) } catch { errorMessage = error.userFacingText }
        }
    }

    func pause() { perform { try await $0.pause() } }
    func resume() { perform { try await $0.resume() } }
    func forceStop() { perform { try await $0.forceStop() } }

    /// Graceful stop: through the agent when it is connected, otherwise the virtual power button.
    func stop() {
        captureThumbnail()
        if agent != nil { link.requestGuestShutdown() }
        perform { try await $0.requestStop() }
    }

    /// A Linux guest must let go of its shared folders before its state can be saved.
    private func withholdShares(_ withheld: Bool) async {
        guard sharedFolders.kind == "9p", !sharedFolders.names.isEmpty, agent != nil else { return }
        sharedFolders.withheld = withheld
        link.notifySharesChanged()
        if withheld { try? await Task.sleep(nanoseconds: 2_500_000_000) }
    }

    /// Saves the VM's memory to disk and stops it. Starting it again continues where it was.
    func suspend() {
        guard canSuspend, let engine else { return }
        captureThumbnail()
        busy = "Suspending…"
        Task {
            await withholdShares(true)
            do { try await engine.suspend() }
            catch {
                errorMessage = error.userFacingText
                await withholdShares(false)
            }
            busy = nil
            refreshSuspended()
        }
    }

    /// Throws a suspended VM's saved memory away, as if its power had been cut.
    func discardSuspendedState() {
        guard state == .stopped || state == .error else { return }
        bundle.discardSuspendState()
        refreshSuspended()
    }

    // MARK: Seamless mode

    /// Set while the guest's program windows are shown as Mac windows.
    @Published private(set) var seamless: SeamlessController?
    private var sizeBeforeSeamless: CGSize?
    var isSeamless: Bool { seamless != nil }
    /// Needs the guest's screen (QEMU engine) and guest tools that can list windows (capability bit 6).
    var canSeamless: Bool {
        busy == nil && state == .running && screen != nil && (agent?.capabilities ?? 0) & 64 != 0 && !seamlessBlockedBy3D && (config.guestOS != .linux || LinuxIntegration.seamlessEnabled)
    }
    /// Windows with 3D acceleration: its 3D display driver offers only a fixed table of screen sizes, so the
    /// guest's desktop cannot match the Mac screen and windows could not be placed exactly on it.
    var seamlessBlockedBy3D: Bool { Self.seamlessBlockedBy3D(config) }
    nonisolated static func seamlessBlockedBy3D(_ config: VMConfig) -> Bool {
        config.guestOS == .windows11arm && config.display.accelerated3D == true
    }
    nonisolated static let seamless3DNote = "Seamless Mode is not available while 3D acceleration is on: the 3D display driver offers only fixed screen sizes, so Windows’ desktop cannot match the Mac screen. Turn 3D off under Configure > Hardware > Graphics to use Seamless Mode."

    /// Hides the VM window and shows each of the guest's program windows as a Mac window.
    /// Guest pixels per Mac point in Seamless Mode: the screen's backing scale when the VM is set to
    /// Retina resolution and its guest tools can set the guest's scale (capability bit 15), else 1.
    var seamlessScale: CGFloat { seamlessPlan().scale }
    /// Whether Seamless Mode may give the guest more pixels than points (Retina resolution).
    private var seamlessRetinaAllowed: Bool {
        config.behaviorOrDefault.seamlessRetina && (agent?.capabilities ?? 0) & (1 << 15) != 0
    }
    /// How the guest's desktop is laid over every Mac display right now.
    func seamlessPlan() -> GuestWindowLayout.DesktopPlan { SeamlessController.desktopPlan(retina: seamlessRetinaAllowed) }
    /// True while the guest's scale is raised for Seamless Mode; leaving the mode puts it back.
    private var scaledForSeamless = false
    /// The window's size in points the last time it changed, and the scale (percent) Tandem asked Windows for
    /// to match a Retina-sized screen (nil: none asked for). See `adjustGuestScale`.
    var viewPointSize: CGSize?
    var retinaScaleRequested: Int?
    var retinaScaleTask: Task<Void, Never>?
    /// True while the guest's work area is limited to the main display; leaving the mode puts it back.
    private var workAreaForSeamless = false

    /// Sizes the guest's desktop for a plan: its pixels, its display scale and, over several displays,
    /// the work area for maximised windows. The scale and work area go after the resolution change.
    private func applySeamlessPlan(_ plan: GuestWindowLayout.DesktopPlan, for controller: SeamlessController) {
        controller.plan = plan
        windowResized(to: plan.pixels, inPixels: true)
        let scale = plan.scale
        let spansDisplays = plan.mainWorkArea.size != plan.pixels
        let canSetWorkArea = (agent?.capabilities ?? 0) & (1 << 17) != 0
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard let self, self.seamless === controller else { return }
            if scale > 1 {
                self.scaledForSeamless = true
                self.link.setDisplayScale(Int((scale * 100).rounded()))
            } else if self.scaledForSeamless {
                // Several displays no longer fit at 2x: back to the guest's own scale.
                self.link.setDisplayScale(0)
                self.scaledForSeamless = false
            }
            if spansDisplays, canSetWorkArea {
                self.workAreaForSeamless = true
                self.link.setWorkArea(plan.mainWorkArea)
            } else if self.workAreaForSeamless {
                self.link.setWorkArea(nil)
                self.workAreaForSeamless = false
            }
        }
    }

    func enterSeamless() {
        guard canSeamless, seamless == nil, let screen else { return }
        sizeBeforeSeamless = CGSize(width: screen.size.width, height: screen.size.height)
        let controller = SeamlessController(client: screen, link: link, name: config.name, plan: seamlessPlan())
        controller.dragOut.inbox = { [weak self] in
            guard let self, self.sharingPolicy.allowsFilesToMac else { return nil }
            return FileDrop.inboxRoot(self.bundle)
        }
        controller.dragOut.refusal = { [weak self] in
            guard let self else { return "The virtual machine is gone." }
            guard (self.agent?.capabilities ?? 0) & GuestCapability.seamlessExtras != 0 else {
                return "The guest tools in “\(self.config.name)” are too old to drag files out. They update themselves at the next start."
            }
            do { try self.sharingPolicy.requireFilesToMac() } catch { return (error as? VMError)?.errorDescription ?? error.localizedDescription }
            guard self.sharedFolders.port != 0 else { return "The file service for “\(self.config.name)” is not running." }
            return nil
        }
        controller.onDisplaysChanged = { [weak self, weak controller] in
            guard let self, let controller, self.seamless === controller else { return }
            let plan = self.seamlessPlan()
            if plan != controller.plan { self.applySeamlessPlan(plan, for: controller) }
        }
        controller.onWindows = { [weak self] windows in self?.noteWindows(windows) }
        controller.iconProvider = { [weak self] window in self?.image(self?.icon(for: window), points: 64) }
        seamless = controller
        // One turn of the run loop later, so the VM window has let go of the screen first.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.seamless === controller else { return }
            controller.start()
            // The guest's desktop covers every Mac display's usable area: in pixels at Retina
            // resolution, with the guest's scale raised to match, otherwise in points.
            self.applySeamlessPlan(self.seamlessPlan(), for: controller)
        }
    }

    func exitSeamless(reopenWindow: Bool = true) {
        guard let controller = seamless else { return }
        controller.stop()
        seamless = nil
        lastGuestWindows = []
        tileRetry?.cancel()
        tiles.stop()
        if scaledForSeamless { link.setDisplayScale(0); scaledForSeamless = false }
        if workAreaForSeamless { link.setWorkArea(nil); workAreaForSeamless = false }
        if let size = sizeBeforeSeamless { windowResized(to: size, inPixels: true) }
        sizeBeforeSeamless = nil
        // Leaving the mode put the guest's own scale back; a Retina-sized screen needs its scale again.
        retinaScaleRequested = nil
        adjustGuestScale(after: 3)
        if reopenWindow, state.isActive { AppDelegate.shared?.show("vm", id) }
    }

    // MARK: Guest programs and icons

    /// What the guest's Start menu offers, by name (guest tools with capability bit 7).
    @Published private(set) var guestPrograms: [GuestProgram] = []
    /// Icons from the guest: "program:<id>" for a listed program, "app:<file name>" for a running one.
    @Published private(set) var guestIcons: [String: CGImage] = [:]
    /// Icons asked for, so each is asked for once per connection.
    private var askedIcons = Set<String>()
    /// The cache key an asked-for window icon will be stored under.
    private var windowIconKeys: [UInt64: String] = [:]

    private func forgetIconRequests() {
        askedIcons = []
        windowIconKeys = [:]
    }

    private func programsArrived(_ programs: [GuestProgram]) {
        guestPrograms = programs
        for program in programs where askedIcons.insert("program:" + program.id).inserted {
            link.requestIcon(.program(program.id), size: 48)
        }
    }

    private func iconArrived(_ icon: GuestIcon) {
        let key: String? = switch icon.key {
        case .program(let id): "program:" + id
        case .window(let id): windowIconKeys.removeValue(forKey: id)
        }
        guard let key, let image = icon.cgImage else { return }
        guestIcons[key] = image
        seamless?.iconsChanged()
        updateTiles()
    }

    // MARK: Launching from the Mac (LaunchPipeline.swift, MacApps.swift)

    /// What a Mac-side launch is doing ("Opening Notepad…"), shown in place of the VM's state.
    @Published var launchStatus: String?
    /// Waiters for the guest's answers, and the queue that keeps launches one after another.
    let launches = LaunchState()
    /// The programs of this VM that have a launcher on the Mac, by program id.
    @Published var macLaunchers: [String: URL] = [:]
    /// For those launchers: the program's file name in the guest (lower case) to its program id.
    var macLauncherFiles: [String: String] = [:]

    /// `<share>/<path>` for a Mac file inside a folder this VM may see under its sharing policy (the
    /// profile's folders and, while it runs, those shared until shutdown); nil when it is in none.
    /// This is the one place a launch from the Mac asks whether a document may go into the guest.
    func sharedPath(for file: URL) -> String? { SharedFolderService.sharedPath(for: file.path, in: sharingPolicy) }

    /// Shares a Mac folder with the VM, read and write, through the sharing profile like any other
    /// change: for good while the VM is off, until it shuts down while it runs.
    func share(folder: URL) throws {
        let path = folder.standardizedFileURL.path
        // Already inside a shared folder: nothing to add.
        guard sharedPath(for: folder.appendingPathComponent("any")) == nil else { return }
        if state.isActive {
            try shareTemporarily(path: path, readOnly: false)
        } else {
            var profile = bundle.config.sharing
            profile.folders.append(try SharingEdit.folder(path: path, name: nil, readOnly: false, taken: profile.folders.map(\.name)))
            try setSharing(profile)
        }
    }

    // MARK: Usage and the idle timer (PowerMonitor.swift)

    let powerState = PowerState()
    /// The last reading of what the VM uses and whether it is idle. Not published: it changes every few
    /// seconds, and the views that show it refresh themselves.
    var usage: VMUsage?
    /// The VM's own process, where it has one (QEMU engine).
    var processIdentifier: Int32? { (engine as? QEMUEngine)?.processIdentifier }

    // MARK: Dock tiles for the guest's programs

    private lazy var tiles = GuestAppTiles(vm: id, vmName: config.name)
    private var lastGuestWindows: [GuestWindow] = []
    private var tileRetry: Task<Void, Never>?

    /// The Start menu entry a window belongs to, by its title or its program's file name.
    func program(for window: GuestWindow) -> GuestProgram? {
        let title = window.title
        // A program the user keeps a launcher for is known by its file, whatever its window is called.
        if let id = macLauncherFiles[window.app.lowercased()], let match = guestPrograms.first(where: { $0.id == id }) { return match }
        // Windows programs put their name last in the title, after a dash of one kind or another.
        let named = { (name: String) in title == name || [" - ", " — ", " – "].contains { title.hasSuffix($0 + name) } }
        if let match = guestPrograms.first(where: { named($0.name) }) { return match }
        let stem = window.app.lowercased().replacingOccurrences(of: ".exe", with: "")
        return stem.isEmpty ? nil : guestPrograms.first { $0.name.lowercased() == stem }
    }

    /// What a window's Dock tile stands for and is called. Nil for windows that get no tile.
    func tileProgram(for window: GuestWindow) -> GuestAppTiles.Program? {
        guard window.kind == .app, !window.title.isEmpty else { return nil }
        let listed = program(for: window)
        // A program the user keeps a launcher for: the launcher is its tile, so the Dock shows it once.
        if let listed, macLaunchers[listed.id] != nil { return GuestAppTiles.Program(key: "program:" + listed.id, name: listed.name) }
        // Its other windows too (a dialog, a start screen), which carry the same program file but another title.
        if Self.appIconKey(window) != nil,
           let sibling = lastGuestWindows.lazy.filter({ $0.id != window.id && $0.app == window.app }).compactMap({ self.program(for: $0) }).first(where: { self.macLaunchers[$0.id] != nil }) {
            return GuestAppTiles.Program(key: "program:" + sibling.id, name: sibling.name)
        }
        if let key = Self.appIconKey(window) {
            let stem = window.app.replacingOccurrences(of: ".exe", with: "", options: [.caseInsensitive, .anchored, .backwards])
            return GuestAppTiles.Program(key: key, name: listed?.name ?? stem.prefix(1).uppercased() + stem.dropFirst())
        }
        return listed.map { GuestAppTiles.Program(key: "program:" + $0.id, name: $0.name) }
    }

    /// Keeps the Dock tiles in step with the programs that have windows (Seamless Mode only).
    func updateTiles() {
        tiles.override = config.behaviorOrDefault.dockTiles
        guard isSeamless else { tiles.stop(); return }
        var programs: [GuestAppTiles.Program] = []
        for window in lastGuestWindows {
            guard let program = tileProgram(for: window), !programs.contains(where: { $0.key == program.key }) else { continue }
            programs.append(program)
        }
        tiles.launcher = { [macLaunchers] program in
            program.key.hasPrefix("program:") ? macLaunchers[String(program.key.dropFirst("program:".count))] : nil
        }
        tiles.update(programs) { [guestIcons] program in guestIcons[program.key] }
        // A program still waiting for its icon gets its tile after the wait, icon or not.
        tileRetry?.cancel()
        if tiles.hasPending {
            tileRetry = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled { self?.updateTiles() }
            }
        }
    }

    /// A Dock tile was chosen: bring that program's front window forward.
    func activateProgram(_ key: String) {
        guard let window = openGuestWindows.first(where: { tileProgram(for: $0)?.key == key }) else { return }
        activateGuestWindow(window.id)
    }

    /// A Dock tile was quit: close that program's windows. One that asks about unsaved work stays open.
    func closeProgram(_ key: String) {
        let ids = openGuestWindows.filter { tileProgram(for: $0)?.key == key }.map(\.id)
        // One at a time: a queued window action replaces the one before it.
        Task { [weak self] in
            for id in ids {
                self?.link.windowAction(.close, window: id)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// Every store app's window belongs to one frame-host program, whose icon says nothing about the app.
    private static func appIconKey(_ window: GuestWindow) -> String? {
        let app = window.app.lowercased()
        return app.isEmpty || app == "applicationframehost.exe" ? nil : "app:" + app
    }

    /// Asks for the icons of programs whose windows are on screen and that have none yet.
    private func noteWindows(_ windows: [GuestWindow]) {
        lastGuestWindows = windows
        defer { updateTiles() }
        guard (agent?.capabilities ?? 0) & 128 != 0 else { return }
        for window in windows where window.kind == .app {
            guard let key = Self.appIconKey(window), askedIcons.insert(key).inserted else { continue }
            windowIconKeys[window.id] = key
            link.requestIcon(.window(window.id), size: 128)
        }
    }

    /// The icon of the program a guest window belongs to. A window without one of its own (store apps)
    /// takes the icon of the Start menu entry it is named after.
    func icon(for window: GuestWindow) -> CGImage? {
        if let key = Self.appIconKey(window), let icon = guestIcons[key] { return icon }
        let title = window.title
        guard let program = guestPrograms.first(where: { title == $0.name || title.hasSuffix(" - " + $0.name) }) else { return nil }
        return guestIcons["program:" + program.id]
    }

    func icon(for program: GuestProgram) -> CGImage? { guestIcons["program:" + program.id] }

    /// An icon at menu size.
    func image(_ icon: CGImage?, points: CGFloat = 16) -> NSImage? {
        icon.map { NSImage(cgImage: $0, size: NSSize(width: points, height: points)) }
    }

    /// Starts a program in the guest. Its window should appear on the Mac desktop, so a VM that is
    /// shown in its own window goes into Seamless Mode first.
    func launch(_ program: GuestProgram) {
        guard state == .running, agent != nil else { return }
        if canSeamless, !isSeamless { enterSeamless() }
        link.launchProgram(id: program.id)
    }

    /// The guest's program windows while in Seamless Mode, front-most first, minimised ones included.
    var openGuestWindows: [GuestWindow] { seamless?.programWindows ?? [] }

    func activateGuestWindow(_ id: UInt64) { seamless?.activate(id) }

    /// The guest tools can restart the guest's system cleanly.
    var canRestart: Bool { busy == nil && state == .running && (agent?.capabilities ?? 0) & 32 != 0 }

    /// Asks the guest's system to restart, as its own Restart command would.
    func restart() {
        guard canRestart else { return }
        link.requestGuestRestart()
    }

    /// Restarts the guest without asking it (QEMU engine).
    func reset() {
        guard canReset, let qemu = engine as? QEMUEngine else { return }
        Task { do { try await qemu.reset() } catch { errorMessage = error.userFacingText } }
    }

    func forceStopAndWait() async {
        guard let engine, state.isActive else { return }
        try? await engine.forceStop()
    }

    // MARK: Editing (only while stopped)

    // MARK: Screen picture and keys

    func guestImage() -> CGImage? {
        guard let screen else { return nil }
        let shot = screen.snapshot()
        guard shot.size.width > 0, shot.size.height > 0, let provider = CGDataProvider(data: shot.pixels as CFData) else { return nil }
        return CGImage(width: shot.size.width, height: shot.size.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: shot.size.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func png(_ image: CGImage, maxWidth: Int? = nil) -> Data? {
        var source = image
        // A width from a control request: at least 16, so the product below cannot overflow or go negative.
        if let maxWidth = maxWidth.map({ max($0, 16) }), image.width > maxWidth {
            let height = image.height * maxWidth / image.width
            guard let context = CGContext(data: nil, width: maxWidth, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: height))
            guard let scaled = context.makeImage() else { return nil }
            source = scaled
        }
        return NSBitmapImageRep(cgImage: source).representation(using: .png, properties: [:])
    }

    /// Saves a small picture of the screen for Control Center. A black screen (guest still booting) is skipped.
    func captureThumbnail() {
        guard let image = guestImage(), let data = Self.png(image, maxWidth: 512), data.count > 4000 else { return }
        try? data.write(to: bundle.url.appendingPathComponent("thumbnail.png"), options: .atomic)
        thumbnail = NSImage(data: data)
    }

    func saveScreenshotToDesktop() {
        guard let image = guestImage(), let data = Self.png(image) else { return }
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let url = desktop.appendingPathComponent("\(config.name) \(stamp).png")
        do { try data.write(to: url); NSWorkspace.shared.activateFileViewerSelecting([url]) }
        catch { errorMessage = "The screenshot could not be saved: \(error.localizedDescription)" }
    }

    /// Presses the keys together and releases them in reverse order. Values are PC scancodes; 0x80 marks an extended key.
    func sendKeys(_ scancodes: [UInt8]) {
        guard let screen else { return }
        for code in scancodes { screen.sendKey(scancode: code, down: true) }
        for code in scancodes.reversed() { screen.sendKey(scancode: code, down: false) }
    }

    // MARK: USB devices

    /// Devices handed to this VM, by `HostUSBDevice.qemuID`.
    @Published private(set) var usbAttached: Set<String> = []
    /// Only the QEMU engine can pass USB devices through, and only while the VM runs.
    var supportsUSB: Bool { engine is QEMUEngine && state == .running }

    /// Closes every way into the running guest when the sharing policy stops allowing connections in:
    /// the published services stop listening and QEMU drops its port forwards.
    func closeInboundPaths() {
        publisher.stop()
        serviceStatuses = []
        if let qemu = engine as? QEMUEngine { Task { await qemu.closeInboundForwards() } }
    }

    /// Takes the Mac's USB devices back when the sharing policy stops allowing them.
    func enforceUSBPolicy() {
        guard !sharingPolicy.usbAllowed, let qemu = engine as? QEMUEngine, !usbAttached.isEmpty else { return }
        let policy = sharingPolicy
        Task {
            _ = await qemu.enforceUSB(policy)
            usbAttached = []
        }
    }

    func toggleUSB(_ device: HostUSBDevice) {
        guard let qemu = engine as? QEMUEngine else { return }
        let attached = usbAttached.contains(device.qemuID)
        Task {
            do {
                if attached { try await qemu.detachUSB(device); usbAttached.remove(device.qemuID) }
                else { try await qemu.attachUSB(device, policy: sharingPolicy); usbAttached.insert(device.qemuID) }
            } catch {
                errorMessage = error.userFacingText
            }
        }
    }

    // MARK: Display follows the window

    /// Set when this connection's guest tools were asked for the configured size.
    private var configuredSizeRequested = false

    /// Windows keeps the size it last used for a display device, so a VM can come up at another size than
    /// the one configured (a new 3D display driver starts at 1024x768). The first time the guest tools
    /// report a different size, the configured one is asked for; a window that is open asks for its own
    /// size afterwards anyway. Drivers with a fixed table of sizes get the closest size that fits.
    private func applyConfiguredDisplaySizeIfNeeded(_ report: DisplayReport) {
        guard !configuredSizeRequested, config.display.dynamicResize, state == .running, seamless == nil,
              let agent, agent.capabilities & 4 != 0, report.width > 0, report.height > 0 else { return }
        if config.guestOS == .windows11arm && config.display.virtioGPU != true && config.display.accelerated3D != true { return }
        configuredSizeRequested = true
        let width = config.display.width, height = config.display.height
        guard Int(report.width) != width || Int(report.height) != height else { return }
        screen?.requestDesktopSize(width: width, height: height)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.link.requestDisplayResize(width: width, height: height)
        }
    }

    private var resizeTask: Task<Void, Never>?

    /// The guest display follows the window: once the window has stopped changing size, the display
    /// server is asked for the new size, then the guest agent switches the guest to it. Needs the agent
    /// (capability bit 2) and, on Windows, the display driver.
    ///
    /// `size` is the window's size in points. With "Use Retina resolution" the guest gets that many pixels
    /// times the screen's backing scale, and Windows' display scale is raised to match (`adjustGuestScale`).
    /// `inPixels` is for callers that already know the guest's size in pixels (Seamless Mode).
    func windowResized(to size: CGSize, inPixels: Bool = false) {
        if seamless == nil && !inPixels { viewPointSize = size }
        guard config.display.dynamicResize, let screen, let agent, agent.capabilities & 4 != 0, state == .running else { return }
        if config.guestOS == .windows11arm && config.display.virtioGPU != true { return }
        let factor = !inPixels && config.display.useRetinaResolution ? Self.windowBackingScale : 1
        // Even numbers, within what the display device accepts.
        let (width, height) = GuestDisplayScale.guestPixels(forPoints: Double(size.width), Double(size.height), factor: Double(factor))
        if !inPixels { adjustGuestScale(after: 2.4) }
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self, self.screen === screen else { return }
            let current = screen.size
            guard current.width != width || current.height != height else { return }
            screen.requestDesktopSize(width: width, height: height)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self.link.requestDisplayResize(width: width, height: height)
            // Start at this size next time.
            self.bundle.config.display.width = width
            self.bundle.config.display.height = height
            try? self.bundle.save()
        }
    }

    // MARK: Snapshots

    private func requireStopped(_ action: String) throws {
        guard state == .stopped || state == .error else { throw VMError("Shut the VM down before \(action).") }
    }

    var snapshots: [VMSnapshot] { SnapshotStore(bundle: bundle).list() }

    /// Takes a snapshot. Of a running VM it includes the memory, so going back to it resumes the VM
    /// where it was; the VM pauses for as long as that takes to write.
    func takeSnapshot(named name: String, note: String) async throws {
        guard busy == nil else { throw VMError("The VM is busy: \(busy ?? "")") }
        let store = SnapshotStore(bundle: bundle)
        if state == .running || state == .paused, let engine {
            captureThumbnail() // the snapshot's picture
            busy = "Creating snapshot…"
            defer { busy = nil }
            await withholdShares(true)
            do {
                try await engine.prepareSnapshot()
                // The copy runs off the main actor under the running VM's own lease.
                let config = bundle.config
                let result: Result<VMSnapshot, Error>
                do {
                    result = .success(try await BundleWork.run(bundle, purpose: "taking a snapshot", holding: engine.bundleLease) {
                        try store.create(name: name, note: note, config: config)
                    })
                } catch { result = .failure(error) }
                try await engine.finishSnapshot()
                await withholdShares(false)
                _ = try result.get()
            } catch {
                await withholdShares(false)
                throw error
            }
        } else {
            try requireStopped("taking a snapshot")
            busy = "Creating snapshot…"
            defer { busy = nil }
            let config = bundle.config
            _ = try await BundleWork.run(bundle, purpose: "taking a snapshot") { try store.create(name: name, note: note, config: config) }
        }
        objectWillChange.send()
    }

    /// Each snapshot with the one it follows, and the one the current state follows.
    var snapshotParents: [UUID: UUID?] { SnapshotStore(bundle: bundle).parents() }
    var snapshotHead: UUID? { SnapshotStore(bundle: bundle).currentParent() }

    /// The snapshot marked as the baseline: the only one an AI tool may go back to (see `AITier`).
    var snapshotBaseline: UUID? { SnapshotStore(bundle: bundle).baseline() }

    /// Marks a snapshot as the baseline; nil takes the mark away.
    func setSnapshotBaseline(_ snapshot: VMSnapshot?) throws {
        try SnapshotStore(bundle: bundle).setBaseline(snapshot?.id)
        objectWillChange.send()
    }

    func snapshotThumbnail(_ snapshot: VMSnapshot) -> NSImage? {
        NSImage(contentsOf: SnapshotStore(bundle: bundle).thumbnailURL(snapshot.id))
    }

    func renameSnapshot(_ snapshot: VMSnapshot, name: String, note: String) throws {
        try SnapshotStore(bundle: bundle).rename(snapshot.id, name: name, note: note)
        objectWillChange.send()
    }

    /// Puts the VM back to a snapshot, first saving the current state under `savingCurrentAs` if given.
    /// A running VM is stopped first, and started again afterwards so that it ends up where the snapshot was.
    func goTo(_ snapshot: VMSnapshot, savingCurrentAs name: String?) async throws {
        if let name { try await takeSnapshot(named: name, note: "") }
        let wasActive = state.isActive
        if wasActive {
            busy = "Reverting to snapshot…"
            defer { busy = nil }
            await forceStopAndWait()
            for _ in 0..<100 where state.isActive { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        try await revert(to: snapshot)
        thumbnail = NSImage(contentsOf: bundle.url.appendingPathComponent("thumbnail.png"))
        objectWillChange.send()
        if wasActive { busy = nil; start() }
    }

    func snapshotIncludesRunningState(_ snapshot: VMSnapshot) -> Bool {
        SnapshotStore(bundle: bundle).includesRunningState(snapshot.id)
    }

    func snapshotSize(_ snapshot: VMSnapshot) -> (total: Int64, exclusive: Int64) {
        SnapshotStore(bundle: bundle).size(of: snapshot.id)
    }

    func revert(to snapshot: VMSnapshot) async throws {
        try requireStopped("going back to a snapshot")
        let store = SnapshotStore(bundle: bundle), id = snapshot.id
        let wasBusy = busy != nil
        if !wasBusy { busy = "Going back to snapshot…" }
        defer { if !wasBusy { busy = nil } }
        // Off the main actor, under the VM's lease: nothing else may run or change the VM meanwhile.
        try await BundleWork.run(bundle, purpose: "going back to a snapshot") { try store.revertKeepingAccess(to: id) }
        bundle = try VMBundle.load(from: bundle.url)
        refreshSharingPolicy()
        refreshSuspended()
    }

    func deleteSnapshot(_ snapshot: VMSnapshot) async throws {
        let store = SnapshotStore(bundle: bundle), id = snapshot.id
        // A running VM's own lease covers it; otherwise one is taken for the deletion.
        try await BundleWork.run(bundle, purpose: "deleting a snapshot", holding: engine?.bundleLease) { try store.delete(id) }
        objectWillChange.send()
    }

    func apply(_ newConfig: VMConfig) throws {
        guard state == .stopped || state == .error else { throw VMError("Stop the VM before changing its settings.") }
        guard !isSuspended else { throw VMError("The VM is suspended. Resume it and shut it down before changing its settings.") }
        let problems = newConfig.validate()
        guard problems.isEmpty else { throw VMError("These settings are not valid.", detail: problems.joined(separator: "\n")) }
        // Nothing else may run or change the VM while its disks grow and its settings are written.
        let lease = try BundleLease.acquire(bundle, purpose: "having its settings changed")
        defer { lease.release() }
        for (old, new) in zip(bundle.config.disks, newConfig.disks) where new.sizeGiB != old.sizeGiB {
            guard new.sizeGiB > old.sizeGiB else { throw VMError("A disk cannot be made smaller.") }
            let url = bundle.diskURL(old)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            switch old.format {
            case .raw: try DiskImage.growRaw(at: url, toGiB: new.sizeGiB)
            case .qcow2: try QEMUToolchain.run(try QEMUToolchain.locate().qemuImg, ["resize", url.path, "\(new.sizeGiB)G"])
            }
        }
        var newConfig = newConfig
        // What Tandem installed in the guest is not a setting: keep it, and keep or drop the driver disc with 3D.
        newConfig.display.windows3DDriver = bundle.config.display.windows3DDriver
        newConfig.removableMedia.removeAll { $0.kind == .driverDisc }
        if newConfig.display.accelerated3D == true {
            newConfig.removableMedia += bundle.config.removableMedia.filter { $0.kind == .driverDisc }
        } else {
            try? FileManager.default.removeItem(at: bundle.url.appendingPathComponent(Windows3DDriver.discFileName))
        }
        bundle.config = newConfig
        refreshSharingPolicy()
        try bundle.save()
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sessions: [VMSession] = []
    @Published var selection: UUID?
    @Published var loadFailures: [String] = []
    @Published var fatalError: String?
    @Published private(set) var toolchainNote: String?
    /// Counts changes to any VM. The menu bar takes it as an input, which is what makes SwiftUI rebuild
    /// the menus when a VM changes state while no window changes focus.
    @Published private(set) var menuRevision = 0

    private var library: VMLibrary?
    /// Downloads under way, by VM (ProvisioningJobs.swift).
    var provisioningTasks: [UUID: Task<Void, Never>] = [:]
    /// Why the last download or preparation failed; shown once by Control Center.
    @Published var provisioningError: String?
    private let pasteboard = PasteboardBridge()
    private var clipboardTimer: Timer?
    /// Samples what every VM uses and runs the idle timers (PowerMonitor.swift).
    var powerTimer: Timer?
    private var sessionObservers: [UUID: AnyCancellable] = [:]
    /// Reloads the list when bundles arrive in or leave the VM folders (vmctl, the Finder).
    private var libraryWatcher: LibraryWatcher?

    init() {
        do {
            if let home = ProcessInfo.processInfo.environment["TANDEM_HOME"] {
                library = try VMLibrary(rootDirectory: URL(fileURLWithPath: home))
            } else {
                library = try VMLibrary()
            }
        } catch {
            fatalError = error.localizedDescription
        }
        // Older builds registered bundles that are in the VMs folder anyway, and kept entries for
        // bundles since deleted.
        library?.pruneRegistry()
        reload()
        watchLibraryFolders()
        recoverAfterCrash()
        checkToolchain()
        // The Dock tiles of guest programs are small apps of their own; they report here when chosen or quit.
        for (name, isClose) in [(GuestAppBundle.activateNotification, false), (GuestAppBundle.closeNotification, true)] {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                guard let vm = (note.userInfo?["vm"] as? String).flatMap(UUID.init(uuidString:)),
                      let program = note.userInfo?["program"] as? String else { return }
                Task { @MainActor in
                    guard let session = self?.sessions.first(where: { $0.id == vm }) else { return }
                    if isClose { session.closeProgram(program) } else { session.activateProgram(program) }
                }
            }
        }
        // Launchers (Dock, Spotlight, Finder's Open With) leave requests to open a program or documents.
        watchLaunchRequests()
        startPowerMonitor()
        // Mac clipboard to guests: poll the change count (there is no pasteboard notification).
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pushClipboardIfChanged() }
        }
    }

    /// Shown once at launch when VMs were left running by a Tandem that crashed or was force-quit.
    @Published var recoveryNotice: String?

    /// Cleans up after VMs whose Tandem ended without stopping them: leftover processes, sockets, run
    /// files and half-written suspend files (CrashRecovery), and says so once.
    private func recoverAfterCrash() {
        let outcomes = sessions.compactMap { CrashRecovery.recover($0.bundle) }
        guard !outcomes.isEmpty else { return }
        for outcome in outcomes {
            print("recovery: \(outcome.vmName): stopped \(outcome.stoppedProcesses) processes, removed \(outcome.removedItems)")
        }
        recoveryNotice = outcomes.map(\.message).joined(separator: "\n\n")
    }

    var libraryPath: String { library?.vmsDirectory.path ?? "" }
    /// The library's own folder: registry, download cache.
    var libraryRoot: String { library?.rootDirectory.path ?? VMLibrary.defaultRoot().path }
    var usesDefaultVMsFolder: Bool { library.map { $0.vmsDirectory.standardizedFileURL == $0.defaultVMsDirectory.standardizedFileURL } ?? true }

    /// Changes where new and imported VMs are kept; nil restores the default folder.
    func setVMsFolder(_ url: URL?) throws {
        guard let library else { throw VMError("The VM library is not available.") }
        try library.setVMsDirectory(url)
        objectWillChange.send()
        reload()
        watchLibraryFolders()
    }
    var selectedSession: VMSession? { sessions.first { $0.id == selection } }
    /// The VM whose windows are shown as Mac windows, for menus when one of those windows is in front.
    var seamlessSession: VMSession? { sessions.first { $0.isSeamless } }
    var runningCount: Int { sessions.filter { $0.state.isActive }.count }

    /// Watches the default and the chosen VM folder. A bundle still being written when the change is
    /// reported fails to load; it is tried again a few seconds later.
    private func watchLibraryFolders() {
        guard let library else { return }
        if libraryWatcher == nil {
            libraryWatcher = LibraryWatcher { [weak self] in
                Task { @MainActor in self?.libraryFoldersChanged() }
            }
        }
        libraryWatcher?.watch(library.libraryFolders)
    }

    private func libraryFoldersChanged() {
        reload()
        guard !loadFailures.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.reload() }
    }

    func reload() {
        guard let library else { return }
        let listing = library.list()
        loadFailures = listing.failures.map { "\($0.url.lastPathComponent): \($0.reason)" }
        var result: [VMSession] = []
        for bundle in listing.bundles {
            if let existing = sessions.first(where: { $0.id == bundle.id }) {
                if !existing.state.isActive { existing.bundle = bundle }
                result.append(existing)
            } else {
                let session = VMSession(bundle: bundle, clipboard: pasteboard)
                // Re-publish when a session changes so the sidebar updates.
                sessionObservers[session.id] = session.objectWillChange.sink { [weak self] _ in
                    self?.objectWillChange.send()
                    // After the change has landed, so the menus are rebuilt from the new state.
                    DispatchQueue.main.async { self?.menuRevision &+= 1 }
                }
                result.append(session)
            }
        }
        sessions = result
        if selection == nil || !sessions.contains(where: { $0.id == selection }) { selection = sessions.first?.id }
    }

    private func checkToolchain() {
        do {
            let toolchain = try QEMUToolchain.locate()
            var notes: [String] = []
            if toolchain.swtpm == nil { notes.append("swtpm is not installed; Windows VMs cannot start (brew install swtpm).") }
            if let warning = toolchain.versionWarning { notes.append(warning) }
            toolchainNote = notes.isEmpty ? nil : notes.joined(separator: " ")
        } catch {
            toolchainNote = "QEMU is not installed; Windows VMs are unavailable (brew install qemu swtpm)."
        }
    }

    private func pushClipboardIfChanged() {
        guard let text = pasteboard.pollForChange(), !text.isEmpty else { return }
        for session in sessions where session.agent != nil && session.sharingPolicy.clipboard.toGuest { session.link.notifyClipboardChanged(text) }
    }

    /// The library, for the importer.
    var vmLibrary: VMLibrary? { library }

    func imported(_ bundle: VMBundle) {
        reload()
        selection = bundle.id
    }

    /// `windows`: answers for an unattended Windows install; the VM then installs itself on its first start.
    func create(_ config: VMConfig, windows: WindowsUnattendOptions? = nil) throws {
        guard let library else { throw VMError("The VM library is not available.") }
        var bundle = try library.create(config)
        if config.engine == .qemu {
            // Create the qcow2 disk now so a missing QEMU install is reported at creation, not first start.
            let toolchain = try QEMUToolchain.locate()
            try QEMUEngine.prepare(bundle: bundle, toolchain: toolchain, paths: QEMURunPaths.forVM(bundle.id))
        }
        if let windows {
            do {
                let virtio = ImportDefaults.existingPath(ImportDefaults.virtioISOKey)
                try WindowsInstall.prepare(&bundle, options: windows, virtioISO: virtio.isEmpty ? nil : URL(fileURLWithPath: virtio),
                                           agent: GuestTools.windowsAgent)
            } catch {
                // Leave no half-made VM behind.
                try? library.delete(bundle)
                throw error
            }
        }
        reload()
        selection = bundle.id
    }

    /// The session for a bundle opened from Finder. One the library does not list yet (copied in from
    /// elsewhere) is registered where it is; a copy of a VM already listed is refused rather than
    /// running two VMs with the same identity.
    func openBundle(at url: URL) throws -> VMSession {
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        if let known = sessions.first(where: { $0.bundle.url.resolvingSymlinksInPath().standardizedFileURL == target }) {
            selection = known.id
            return known
        }
        guard let library else { throw VMError("The VM library is not available.") }
        let bundle = try VMBundle.load(from: url)
        if let twin = sessions.first(where: { $0.id == bundle.id }) {
            throw VMError("This is a copy of “\(twin.config.name)”, which is already in Tandem.",
                          detail: "Two copies of one virtual machine cannot both be listed. Remove one, or open the one Tandem lists.")
        }
        // One in the library's own folders is listed by reloading; only a bundle kept elsewhere is registered.
        if !library.isInLibraryFolder(target) { _ = try library.register(externalBundleAt: target) }
        reload()
        guard let session = sessions.first(where: { $0.id == bundle.id }) else { throw VMError("The virtual machine could not be added.") }
        selection = session.id
        return session
    }

    func delete(_ session: VMSession) throws {
        guard !session.state.isActive else { throw VMError("Stop “\(session.config.name)” before deleting it.") }
        // Refused while anything else (vmctl, a clone, a snapshot) uses the VM.
        try BundleLease.with(session.bundle, purpose: "being removed") { _ in try library?.delete(session.bundle, toTrash: true) }
        session.removeAllFromMac()
        sessionObservers[session.id] = nil
        reload()
    }

    func stopEverything() async {
        for session in sessions { await session.forceStopAndWait() }
    }
}
