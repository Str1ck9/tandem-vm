import AppKit
import GuestLink
import VMCore

/// Opening a Windows program, or Mac documents in one, from the Mac side: a launcher in the Dock,
/// Spotlight, or Finder's Open With. Whatever state the VM is in, the steps are the same:
///
///   1. every document must be in a folder the user shares with this VM;
///   2. the VM is started (cold, or resumed from its suspended state) if it is not running;
///   3. the guest tools must answer;
///   4. the VM goes into Seamless Mode, so the program's window appears on the Mac desktop;
///   5. the guest opens the documents in the program, or just starts it;
///   6. the program's window is brought forward on both sides.
///
/// Each step that can fail says so in words the user can act on.

/// Answers from the guest that a launch is waiting for. Safe to call from any thread.
final class LaunchState: @unchecked Sendable {
    typealias ProgramAnswer = (info: GuestProgramInfo, logo: Data)
    private let lock = NSLock()
    private var nextRequest: UInt32 = 1
    private var documentWaiters: [UInt32: CheckedContinuation<GuestDocumentResult?, Never>] = [:]
    private var infoWaiters: [String: [CheckedContinuation<ProgramAnswer?, Never>]] = [:]
    /// The launch in progress; the next one waits for it (main actor only).
    var queue: Task<Void, Never>?
    /// What the last launch ended with: nil for success (for the self-test).
    var lastError: String?
    /// The launchers' copies of the stand-in program have been compared with this Tandem's (main actor only).
    var standInsChecked = false

    func newRequest() -> UInt32 { lock.withLock { nextRequest &+= 1; return nextRequest } }

    /// Nil when the guest did not answer in time, or the VM went away.
    func waitForDocumentResult(request: UInt32, timeout: TimeInterval) async -> GuestDocumentResult? {
        await withCheckedContinuation { continuation in
            lock.withLock { documentWaiters[request] = continuation }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.lock.withLock { self?.documentWaiters.removeValue(forKey: request) }?.resume(returning: nil)
            }
        }
    }

    func documentResultArrived(_ result: GuestDocumentResult) {
        lock.withLock { documentWaiters.removeValue(forKey: result.request) }?.resume(returning: result)
    }

    func waitForProgramInfo(id: String, timeout: TimeInterval) async -> ProgramAnswer? {
        await withCheckedContinuation { continuation in
            lock.withLock { infoWaiters[id, default: []].append(continuation) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                // Whoever is still waiting for this program gives up. An answer in time has emptied the list.
                let waiting = self?.lock.withLock { self?.infoWaiters.removeValue(forKey: id) } ?? nil
                waiting?.forEach { $0.resume(returning: nil) }
            }
        }
    }

    func programInfoArrived(_ info: GuestProgramInfo, logo: Data) {
        let waiting = lock.withLock { infoWaiters.removeValue(forKey: info.id) }
        waiting?.forEach { $0.resume(returning: (info, logo)) }
    }

    /// The VM stopped: nobody will answer.
    func cancelAll() {
        let (documents, infos) = lock.withLock { () -> ([CheckedContinuation<GuestDocumentResult?, Never>], [CheckedContinuation<ProgramAnswer?, Never>]) in
            let d = Array(documentWaiters.values), i = infoWaiters.values.flatMap { $0 }
            documentWaiters = [:]; infoWaiters = [:]
            return (d, i)
        }
        documents.forEach { $0.resume(returning: nil) }
        infos.forEach { $0.resume(returning: nil) }
    }
}

/// Why a launch from the Mac side did not happen, in the user's terms.
struct LaunchError: LocalizedError, Equatable {
    enum Kind: Equatable { case notShared(URL), vm, guestTools, guest }
    var kind: Kind
    var message: String
    var detail: String
    var errorDescription: String? { message }
}

extension VMSession {
    /// How long a cold start may take until the guest tools answer.
    static let guestToolsTimeout: TimeInterval = 300

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return true
    }

    /// The open window of a program, by its place in the guest's program list: the one showing
    /// `document` when given, otherwise the front-most.
    private func window(ofProgram programID: String, showing document: URL? = nil) -> GuestWindow? {
        let candidates = openGuestWindows.filter { program(for: $0)?.id == programID }
        guard let document else { return candidates.first }
        let name = document.lastPathComponent, stem = document.deletingPathExtension().lastPathComponent
        return candidates.first { $0.title.localizedCaseInsensitiveContains(name) }
            ?? candidates.first { $0.title.localizedCaseInsensitiveContains(stem) }
    }

    /// One line per step in the VM's `logs/launch.log`, so a launch that went wrong can be read afterwards.
    func launchLog(_ message: String) {
        let url = bundle.logsDirectory.appendingPathComponent("launch.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8))
    }

    /// Opens `documents` (Mac files) in the program, or just starts it; see the steps at the top.
    /// `programID` is an id from the guest's program list; `name` is what to call it meanwhile.
    func open(programID: String, name: String, documents: [URL]) async throws {
        launchStatus = documents.isEmpty ? "Opening \(name)…" : "Opening \(documents[0].lastPathComponent) in \(name)…"
        noteLaunchFromMac()
        // A launch is a sign of use for the idle timer, from its start to its end.
        defer { launchStatus = nil; noteLaunchFromMac() }
        launchLog("open \(name) [\(programID)] documents \(documents.map(\.path)); the VM is \(statusLabel.lowercased())")

        // 1. Only what the user shares with this VM goes in.
        var shared: [String] = []
        for document in documents {
            guard let path = sharedPath(for: document) else {
                throw LaunchError(kind: .notShared(document),
                                  message: "“\(document.lastPathComponent)” is not in a folder shared with “\(config.name)”.",
                                  detail: "\(config.guestSystemWord) can only open Mac files from folders you share with this virtual machine. Share “\(document.deletingLastPathComponent().lastPathComponent)”, or move the file into a shared folder (Configure > Options > Sharing).")
            }
            shared.append(path)
        }

        // 2. Running, from wherever it was.
        if state == .paused { resume() }
        if state == .stopped || state == .error {
            guard can(.start) else {
                throw LaunchError(kind: .vm, message: "“\(config.name)” cannot be started right now.", detail: statusLabel)
            }
            errorMessage = nil
            start()
        }
        guard await waitUntil(180, { state == .running || state == .error || (state == .stopped && errorMessage != nil) }), state == .running else {
            throw LaunchError(kind: .vm, message: "“\(config.name)” did not start.", detail: errorMessage ?? "It is \(state.label.lowercased()).")
        }

        launchLog("the VM is running")
        // 3. The guest tools.
        guard await waitUntil(Self.guestToolsTimeout, { agent != nil || !state.isActive }), let agent else {
            // Most likely Windows is waiting for a password; show its screen so the user can give it.
            if state.isActive { AppDelegate.shared?.show("vm", id) }
            throw LaunchError(kind: .guestTools, message: "\(config.guestSystemWord) in “\(config.name)” did not get ready.",
                              detail: state.isActive
                                ? "Tandem’s guest tools did not answer. If the guest is waiting at its sign-in screen, sign in and try again."
                                : (errorMessage ?? "The virtual machine stopped."))
        }
        guard agent.capabilities & 128 != 0 else {
            throw LaunchError(kind: .guestTools, message: "“\(config.name)” cannot open programs from the Mac.",
                              detail: "Its guest tools do not list the guest’s programs. This works with Windows and Linux guests.")
        }

        launchLog("guest tools answered (capabilities \(agent.capabilities))")
        // 4. On the Mac desktop.
        if !isSeamless {
            if !seamlessBlockedBy3D, await waitUntil(40, { canSeamless || !state.isActive }), canSeamless {
                enterSeamless()
                _ = await waitUntil(10, { seamless != nil })
                // The guest's desktop is changing size; let it settle before a window opens.
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
            launchLog(isSeamless ? "in Seamless Mode" : seamlessBlockedBy3D ? "not in Seamless Mode (3D acceleration is on)" : "not in Seamless Mode (screen \(screen != nil), busy \(busy ?? "no"), state \(state.rawValue)); the program opens in the VM's own window")
            // Without Seamless Mode the program is still opened; show the VM's window so it can be seen.
            if !isSeamless, state.isActive { AppDelegate.shared?.show("vm", id) }
        }

        // 5. The program, with the documents.
        if shared.isEmpty {
            if let window = window(ofProgram: programID) {
                activateGuestWindow(window.id)
                launchLog("window “\(window.title)” brought forward (the program was already open)")
                return
            }
            // The guest starts only programs it has listed since it connected.
            guard await waitUntil(60, { !guestPrograms.isEmpty || !state.isActive }),
                  let program = guestPrograms.first(where: { $0.id == programID }) else {
                throw LaunchError(kind: .guest, message: "\(name) is not installed in “\(config.name)” any more.",
                                  detail: "\(config.guestSystemWord) no longer lists this program. Remove its launcher from the Mac, or install the program again.")
            }
            link.launchProgram(id: program.id)
        } else {
            guard agent.capabilities & 256 != 0 else {
                throw LaunchError(kind: .guestTools, message: "The guest tools in “\(config.name)” are too old to open Mac documents.",
                                  detail: "They update themselves when the virtual machine starts. Restart it and try again.")
            }
            let request = launches.newRequest()
            link.openDocuments(request: request, program: programID, documents: shared)
            guard let result = await launches.waitForDocumentResult(request: request, timeout: 90) else {
                throw LaunchError(kind: .guest, message: "\(config.guestSystemWord) did not answer the request to open the document.",
                                  detail: state.isActive ? "The guest tools took too long. Try again." : "The virtual machine stopped.")
            }
            switch result.status {
            case .ok: break
            case .unreachable:
                throw LaunchError(kind: .guest, message: "\(config.guestSystemWord) cannot reach “\(documents[0].lastPathComponent)”.",
                                  detail: result.message.isEmpty ? "The shared Mac folder is not connected in \(config.guestSystemWord)." : result.message)
            case .unknownProgram:
                throw LaunchError(kind: .guest, message: "\(name) is not installed in “\(config.name)” any more.", detail: result.message)
            case .failed, .notSupported:
                throw LaunchError(kind: .guest, message: "\(name) could not open “\(documents[0].lastPathComponent)”.", detail: result.message)
            }
        }

        launchLog("the guest started the program")
        // 6. In front, on both sides. A program that takes long to show its window is not an error.
        let document = documents.first
        if await waitUntil(25, { window(ofProgram: programID, showing: document) != nil || !state.isActive }),
           let window = window(ofProgram: programID, showing: document) {
            activateGuestWindow(window.id)
            launchLog("window “\(window.title)” brought forward")
        } else if let window = window(ofProgram: programID) {
            activateGuestWindow(window.id)
            launchLog("window “\(window.title)” brought forward (the document's own window was not found)")
        } else {
            launchLog("no window of the program found to bring forward; open windows: \(openGuestWindows.map(\.title))")
        }
    }

    /// Carries out a launch request after the ones before it, and tells the user if it fails.
    func enqueueLaunch(programID: String, name: String, documents: [URL]) {
        let previous = launches.queue
        launches.queue = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await self.open(programID: programID, name: name, documents: documents)
                self.launches.lastError = nil
            } catch {
                self.launchFailed(error, programID: programID, name: name, documents: documents)
            }
        }
    }

    private func launchFailed(_ error: Error, programID: String, name: String, documents: [URL]) {
        let failure = error as? LaunchError
        let message = failure?.message ?? error.localizedDescription
        let detail = failure?.detail ?? (error as? VMError)?.detail ?? ""
        launches.lastError = message + (detail.isEmpty ? "" : " " + detail)
        launchLog("failed: \(launches.lastError ?? "")")
        // A launcher that asked for a program which has no window now has nothing to stand for.
        if window(ofProgram: programID) == nil {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(GuestAppBundle.quitNotification), object: GuestAppBundle.bundleIdentifier(vm: id, program: "program:" + programID),
                userInfo: nil, deliverImmediately: true)
        }
        // The self-test reads `lastError`; nobody is there to answer a dialog.
        guard SelfTest.directory == nil else { print("launch: failed: \(launches.lastError ?? "")"); return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        if case .notShared(let document)? = failure?.kind {
            let folder = document.deletingLastPathComponent()
            // A running VM gets the folder until it shuts down; a stopped one gets it in its sharing profile.
            alert.addButton(withTitle: state.isActive ? "Share “\(folder.lastPathComponent)” Until Shutdown and Open"
                                                      : "Share “\(folder.lastPathComponent)” and Open")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                try share(folder: folder)
                enqueueLaunch(programID: programID, name: name, documents: documents)
            } catch {
                let second = NSAlert()
                second.messageText = error.localizedDescription
                second.informativeText = (error as? VMError)?.detail ?? ""
                second.runModal()
            }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

extension AppModel {
    /// Picks up launch requests: those left while Tandem was not running, and those announced since.
    func watchLaunchRequests() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(GuestAppBundle.launchNotification), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.collectLaunchRequests() }
        }
        // After the first window is up, so an error has somewhere to show.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.collectLaunchRequests() }
    }

    func collectLaunchRequests() {
        guard let root = vmLibrary?.rootDirectory else { return }
        for request in GuestAppBundle.collect(root: root) { handle(request) }
    }

    func handle(_ request: GuestAppBundle.LaunchRequest) {
        guard request.program.hasPrefix("program:") else { return }
        let programID = String(request.program.dropFirst("program:".count))
        guard let session = sessions.first(where: { $0.id == request.vm }) else {
            guard SelfTest.directory == nil else { print("launch: no such VM \(request.vm)"); return }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "The virtual machine for \(request.name) is no longer in Tandem."
            alert.informativeText = "This launcher belongs to a virtual machine that was removed. You can delete the launcher."
            alert.runModal()
            return
        }
        session.enqueueLaunch(programID: programID, name: request.name, documents: request.documents.map { URL(fileURLWithPath: $0) })
    }
}
