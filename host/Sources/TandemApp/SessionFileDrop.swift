import AppKit
import EngineQEMU
import GuestLink
import Sharing
import VMCore

/// Files dragged from the Finder onto a guest window, and files the guest sends to the Mac.
/// See `FileDrop` for how they travel. One drop per VM at a time.
@MainActor
final class FileTransferCenter {
    static let shared = FileTransferCenter()

    private struct Pending {
        var manifest: FileDrop.Manifest
        var screenPoint: CGPoint
        var lastHeard: Date
    }
    private var pending: [UUID: Pending] = [:]
    private var inboxTimers: [UUID: Timer] = [:]
    private var watchdogs: [UUID: Task<Void, Never>] = [:]
    /// The guest must answer within this long, and say something at least this often while copying.
    static let silenceLimit: TimeInterval = 60

    // MARK: Keeping to the VM's state and policy

    /// Called when the VM starts or stops and whenever its sharing policy changes. Serves the hidden
    /// transfer shares the policy allows and watches the inbox while the guest may send files.
    func update(_ session: VMSession) {
        let id = session.id
        let running = session.state == .running || session.state == .paused || session.state == .starting
        guard running, session.sharedFolders.kind == "webdav" else {
            inboxTimers.removeValue(forKey: id)?.invalidate()
            watchdogs.removeValue(forKey: id)?.cancel()
            if let manifest = pending.removeValue(forKey: id)?.manifest { FileDrop.discard(manifest.id, in: FileDrop.dropRoot(session.bundle)) }
            if !running { FileDrop.clear(session.bundle) }
            return
        }
        let policy = session.sharingPolicy
        var shares: [WebDAVServer.Share] = []
        let fm = FileManager.default
        if policy.allowsFilesToGuest {
            try? fm.createDirectory(at: FileDrop.dropRoot(session.bundle), withIntermediateDirectories: true)
            shares.append(WebDAVServer.Share(name: FileDrop.dropShare, root: FileDrop.dropRoot(session.bundle), readOnly: true))
        }
        if policy.allowsFilesToMac {
            try? fm.createDirectory(at: FileDrop.inboxRoot(session.bundle), withIntermediateDirectories: true)
            shares.append(WebDAVServer.Share(name: FileDrop.inboxShare, root: FileDrop.inboxRoot(session.bundle), readOnly: false))
        }
        if session.sharedFolders.transferShares.map(\.name) != shares.map(\.name) {
            session.sharedFolders.setTransferShares(shares)
        }
        wireLink(session)
        if policy.allowsFilesToMac {
            if inboxTimers[id] == nil {
                let timer = Timer(timeInterval: 1.5, repeats: true) { [weak session] _ in
                    MainActor.assumeIsolated { if let session { FileTransferCenter.shared.collectArrivals(session) } }
                }
                RunLoop.main.add(timer, forMode: .common)
                inboxTimers[id] = timer
            }
        } else {
            inboxTimers.removeValue(forKey: id)?.invalidate()
            // A revoked direction also throws away anything half-sent.
            try? fm.removeItem(at: FileDrop.inboxRoot(session.bundle))
        }
        if !policy.allowsFilesToGuest, let manifest = pending.removeValue(forKey: id)?.manifest {
            FileDrop.discard(manifest.id, in: FileDrop.dropRoot(session.bundle))
        }
    }

    private func wireLink(_ session: VMSession) {
        guard session.link.onDropResult == nil else { return }
        session.link.onDropProgress = { [weak session] progress in
            Task { @MainActor in if let session { FileTransferCenter.shared.progress(progress, session) } }
        }
        session.link.onDropResult = { [weak session] result in
            Task { @MainActor in if let session { FileTransferCenter.shared.finished(result, session) } }
        }
    }

    // MARK: Mac to guest

    /// Why `session` cannot take a drop now, in words for the user; nil when it can.
    func refusal(_ session: VMSession) -> String? {
        guard session.state == .running else { return "“\(session.config.name)” is not running." }
        guard session.config.guestOS == .windows11arm else { return "Dropping files is available for Windows virtual machines only." }
        guard let agent = session.agent else { return "The Tandem guest tools in “\(session.config.name)” are not running yet." }
        guard agent.capabilities & GuestCapability.fileDrop != 0 else { return "The guest tools in “\(session.config.name)” are too old for drag and drop. They update themselves at the next start." }
        do { try session.sharingPolicy.requireFilesToGuest() } catch { return (error as? VMError)?.errorDescription ?? error.localizedDescription }
        guard session.sharedFolders.port != 0 else { return "The file service for “\(session.config.name)” is not running." }
        guard pending[session.id] == nil else { return "Another drop is still being copied into “\(session.config.name)”." }
        return nil
    }

    /// Copies `urls` into the guest at the guest pixel `point`. `screenPoint` places the status panel.
    func drop(_ urls: [URL], on session: VMSession, at point: (x: Int, y: Int), screenPoint: CGPoint) {
        if let reason = refusal(session) { DropHUD.shared.show(reason, at: screenPoint, failed: true); return }
        let root = FileDrop.dropRoot(session.bundle)
        let port = session.sharedFolders.port
        update(session)
        DropHUD.shared.show("Preparing \(Self.describe(urls.map(\.lastPathComponent)))…", at: screenPoint, progress: nil)
        let id = session.id
        Task.detached {
            let result = Result { try FileDrop.stage(urls, in: root) }
            await MainActor.run {
                switch result {
                case .failure(let error):
                    DropHUD.shared.show((error as? VMError)?.errorDescription ?? error.localizedDescription, at: screenPoint, failed: true)
                case .success(var manifest):
                    manifest.port = port
                    FileTransferCenter.shared.send(manifest, to: session, id: id, at: point, screenPoint: screenPoint)
                }
            }
        }
    }

    private func send(_ manifest: FileDrop.Manifest, to session: VMSession, id: UUID, at point: (x: Int, y: Int), screenPoint: CGPoint) {
        let root = FileDrop.dropRoot(session.bundle)
        let data = Data(manifest.guestText.utf8)
        guard data.count <= GuestLinkHost.maxDropManifestBytes else {
            FileDrop.discard(manifest.id, in: root)
            DropHUD.shared.show("Too many files to drop at once. Put them in one folder, or share the folder with the virtual machine.", at: screenPoint, failed: true)
            return
        }
        // The VM may have stopped, or the policy changed, while the files were prepared.
        if let reason = refusal(session) { FileDrop.discard(manifest.id, in: root); DropHUD.shared.show(reason, at: screenPoint, failed: true); return }
        pending[id] = Pending(manifest: manifest, screenPoint: screenPoint, lastHeard: Date())
        DropHUD.shared.show("Copying \(Self.describe(manifest.topLevel)) to \(session.config.name)…", at: screenPoint,
                            progress: manifest.totalBytes > 0 ? 0 : nil)
        session.link.dropFiles(manifest: data, x: point.x, y: point.y)
        appendLog(session, "drop \(manifest.id): \(manifest.items.count) items, \(manifest.totalBytes) bytes at \(point.x),\(point.y)")
        watchdogs[id]?.cancel()
        watchdogs[id] = Task { [weak session] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let session, let current = FileTransferCenter.shared.pending[id], current.manifest.id == manifest.id else { return }
                if Date().timeIntervalSince(current.lastHeard) > Self.silenceLimit {
                    FileTransferCenter.shared.finished(GuestDropResult(id: manifest.id, status: .failed,
                        message: "Windows did not take the files. The guest tools may be busy or not signed in."), session)
                    return
                }
            }
        }
    }

    private func progress(_ progress: GuestDropProgress, _ session: VMSession) {
        guard var current = pending[session.id], current.manifest.id == progress.id else { return }
        current.lastHeard = Date()
        pending[session.id] = current
        let fraction = progress.total > 0 ? Double(progress.bytes) / Double(progress.total) : nil
        DropHUD.shared.show("Copying \(Self.describe(current.manifest.topLevel)) to \(session.config.name)… "
                            + ByteCountFormatter.string(fromByteCount: Int64(progress.bytes), countStyle: .file) + " of "
                            + ByteCountFormatter.string(fromByteCount: Int64(progress.total), countStyle: .file),
                            at: current.screenPoint, progress: fraction)
    }

    private func finished(_ result: GuestDropResult, _ session: VMSession) {
        guard let current = pending[session.id], current.manifest.id == result.id else { return }
        pending[session.id] = nil
        watchdogs.removeValue(forKey: session.id)?.cancel()
        FileDrop.discard(result.id, in: FileDrop.dropRoot(session.bundle))
        appendLog(session, "drop \(result.id): \(result.status.rawValue), \(result.files) files to \(result.folder) \(result.message ?? "")")
        let what = Self.describe(current.manifest.topLevel)
        switch result.status {
        case .copied:
            DropHUD.shared.show("Copied \(what) to \(Self.folderName(result.folder)).", at: current.screenPoint, done: true)
        case .fallback:
            DropHUD.shared.show("Copied \(what) to \(Self.folderName(result.folder)) in Windows: there was no folder under the pointer.",
                                at: current.screenPoint, done: true)
        case .failed:
            DropHUD.shared.show(result.message ?? "Windows could not copy the files.", at: current.screenPoint, failed: true)
        }
        lastResult[session.id] = result
    }

    /// The last drop's outcome per VM, for the self-test.
    private(set) var lastResult: [UUID: GuestDropResult] = [:]
    func isBusy(_ session: VMSession) -> Bool { pending[session.id] != nil }

    // MARK: Guest to Mac

    private func collectArrivals(_ session: VMSession) {
        let inbox = FileDrop.inboxRoot(session.bundle)
        let arrivals = FileDrop.finishedArrivals(in: inbox)
        guard !arrivals.isEmpty else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let home = ProcessInfo.processInfo.environment["TANDEM_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? VMLibrary.defaultRoot()
        let keepRoot = home.appendingPathComponent("Undelivered Files", isDirectory: true)
        var delivered: [URL] = [], kept: [URL] = [], failures: [String] = []
        var leftInInbox = false
        for arrival in arrivals {
            let result = FileDrop.deliver(arrival, from: inbox, to: downloads, keepIn: keepRoot)
            delivered += result.delivered; kept += result.kept; failures += result.failures
            leftInInbox = leftInInbox || result.leftInInbox
        }
        appendLog(session, "received \(delivered.count) from the guest into \(downloads.path)")
        if !failures.isEmpty {
            appendLog(session, "could not deliver \(failures.count) from the guest: \(failures.joined(separator: "; "))"
                      + (kept.isEmpty ? "" : "; kept in \(kept[0].deletingLastPathComponent().path)")
                      + (leftInInbox ? "; some left in \(inbox.path)" : ""))
            lastUndelivered[session.id] = kept
            reportUndelivered(session, failures: failures, kept: kept, inbox: leftInInbox ? inbox : nil)
        }
        guard !delivered.isEmpty else { return }
        lastArrivals[session.id] = delivered
        let screen = NSScreen.main?.visibleFrame ?? .zero
        DropHUD.shared.show("Received \(Self.describe(delivered.map(\.lastPathComponent))) from \(session.config.name) in Downloads.",
                            at: CGPoint(x: screen.midX, y: screen.minY + 120), done: true)
        if ProcessInfo.processInfo.environment["TANDEM_SNAPSHOT_DIR"] == nil {
            NSWorkspace.shared.activateFileViewerSelecting(delivered)
        }
    }

    /// Files received per VM, for the self-test.
    private(set) var lastArrivals: [UUID: [URL]] = [:]
    /// Files that could not be put in Downloads and were kept instead, per VM, for the self-test.
    private(set) var lastUndelivered: [UUID: [URL]] = [:]

    /// Says which files did not reach Downloads and where they are now, with Reveal in Finder.
    private func reportUndelivered(_ session: VMSession, failures: [String], kept: [URL], inbox: URL?) {
        let names = failures.map { String($0.split(separator: ":", maxSplits: 1).first ?? "") }
        var text = "\(Self.describe(names)) from \(session.config.name) could not be put in Downloads.\n\n"
            + failures.prefix(5).joined(separator: "\n")
        if !kept.isEmpty { text += "\n\nNothing was deleted: the files are kept in \(kept[0].deletingLastPathComponent().path)." }
        if let inbox { text += "\n\nSome are still in \(inbox.path)." }
        if ProcessInfo.processInfo.environment["TANDEM_SNAPSHOT_DIR"] != nil { DropHUD.shared.show(text, at: .zero, failed: true); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some files from \(session.config.name) were not delivered"
        alert.informativeText = text
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "OK")
        let reveal = kept.isEmpty ? (inbox.map { [$0] } ?? []) : kept
        if alert.runModal() == .alertFirstButtonReturn, !reveal.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(reveal)
        }
    }

    // MARK: Words

    static func describe(_ names: [String]) -> String {
        switch names.count {
        case 0: return "the files"
        case 1: return "“\(names[0])”"
        case 2: return "“\(names[0])” and “\(names[1])”"
        default: return "“\(names[0])” and \(names.count - 1) more"
        }
    }

    static func folderName(_ windowsPath: String) -> String {
        let last = windowsPath.split(separator: "\\").last.map(String.init) ?? windowsPath
        return last.isEmpty ? windowsPath : "“\(last)”"
    }

    private func appendLog(_ session: VMSession, _ line: String) {
        let url = session.bundle.logsDirectory.appendingPathComponent("file-transfer.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

extension VMSession {
    /// Keeps the hidden transfer shares and the inbox watch in step with the VM (SessionSharing calls it).
    func updateFileTransfers() { FileTransferCenter.shared.update(self) }
}

/// A small status panel near where files were dropped: what is happening, progress, and the outcome.
@MainActor
final class DropHUD {
    static let shared = DropHUD()
    private var panel: NSPanel?
    private let label = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()
    private var hideTask: Task<Void, Never>?
    /// The last text shown, for the self-test.
    private(set) var lastText = ""

    func show(_ text: String, at point: CGPoint, progress: Double? = nil, done: Bool = false, failed: Bool = false) {
        lastText = text
        let panel = self.panel ?? makePanel()
        label.stringValue = text
        label.textColor = failed ? .systemRed : .labelColor
        bar.isHidden = done || failed
        if let progress { bar.isIndeterminate = false; bar.doubleValue = progress * 100 }
        else { bar.isIndeterminate = true; bar.startAnimation(nil) }
        let size = NSSize(width: 340, height: 74)
        var origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height - 24)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX + 8), f.maxX - size.width - 8)
            origin.y = min(max(origin.y, f.minY + 8), f.maxY - size.height - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        hideTask?.cancel()
        if done || failed {
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: failed ? 6_000_000_000 : 3_500_000_000)
                guard !Task.isCancelled else { return }
                self?.panel?.orderOut(nil)
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 74), styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        label.font = .systemFont(ofSize: 12.5)
        label.maximumNumberOfLines = 3
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0; bar.maxValue = 100
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        panel.contentView = effect
        self.panel = panel
        return panel
    }
}

// MARK: Drop target on the guest screen (the VM window and every Seamless window)

extension GuestScreenNSView {
    /// The session whose screen this view shows.
    var session: VMSession? { AppDelegate.shared?.model?.sessions.first { $0.screen === client } }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// The guest pixel under a point of this view's window, the same way mouse events are mapped
    /// (Seamless windows use the pointer's place on the screen).
    func guestPoint(atWindowPoint point: NSPoint) -> (x: Int, y: Int)? {
        guard let window, let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 0, pressure: 0) else { return nil }
        return guestPoint(for: event)
    }

    private func setDropHighlight(_ on: Bool) {
        layer?.borderWidth = on ? 3 : 0
        layer?.borderColor = on ? NSColor.controlAccentColor.cgColor : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let session, !fileURLs(sender).isEmpty, FileTransferCenter.shared.refusal(session) == nil else {
            setDropHighlight(false)
            return []
        }
        setDropHighlight(true)
        // The guest's pointer follows, so its own hover effects show where the files will land.
        if let p = guestPoint(atWindowPoint: sender.draggingLocation) { input.movePointer(toX: p.x, y: p.y) }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { setDropHighlight(false) }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropHighlight(false)
        let urls = fileURLs(sender)
        guard let session, !urls.isEmpty, let p = guestPoint(atWindowPoint: sender.draggingLocation) else { return false }
        let screenPoint = window?.convertPoint(toScreen: sender.draggingLocation) ?? NSEvent.mouseLocation
        FileTransferCenter.shared.drop(urls, on: session, at: p, screenPoint: screenPoint)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { setDropHighlight(false) }
}
