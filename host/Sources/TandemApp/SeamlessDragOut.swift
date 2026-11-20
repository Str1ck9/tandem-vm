import AppKit
import EngineQEMU
import GuestLink
import Sharing
import UniformTypeIdentifiers
import VMCore

/// Dragging files out of a Windows File Explorer window onto the Mac, in Seamless Mode.
///
/// While the user drags from an Explorer window, the Mac windows only cover the guest's windows, so the
/// pointer can leave them. When it does with the button held and no window move or resize under way,
/// the drag is taken over: the guest's drag is cancelled (Escape, then the button released), the guest
/// is asked which files are selected where the drag began, and the Mac carries on the drag with file
/// promises. Finder (or any app that takes files) asks for the files when they are dropped; only then
/// does the guest upload them, through the same hidden inbox share as "Send to > Mac".
@MainActor
final class SeamlessDragOut: NSObject, NSDraggingSource, NSFilePromiseProviderDelegate {
    private enum State {
        case idle
        /// Waiting for the guest to name the selected files.
        case asking(x: Int, y: Int)
        case ready(paths: [String])
        /// The Mac's drag session is under way; nothing more to do until the button goes up.
        case dragging
        /// Nothing to drag (or not allowed); events are swallowed until the button goes up.
        case refused
    }
    private var state = State.idle
    private let client: RFBClient
    private let input: GuestInput
    private let link: GuestLinkHost
    /// The VM's inbox folder, where the guest's uploads land; nil when the VM may not send files to the Mac.
    var inbox: () -> URL? = { nil }
    /// Why files may not come to the Mac now, in words for the user; nil when they may.
    var refusal: () -> String? = { nil }

    init(client: RFBClient, input: GuestInput, link: GuestLinkHost) {
        self.client = client
        self.input = input
        self.link = link
        super.init()
        link.onDragOutItems = { [weak self] items in Task { @MainActor in self?.arrived(items) } }
    }

    func stop() {
        link.onDragOutItems = nil
        state = .idle
    }

    var isActive: Bool { if case .idle = state { return false }; return true }

    /// Called for every drag event of a seamless window. Returns true when drag-out has the drag, so
    /// the event must not go to the guest.
    func dragged(_ event: NSEvent, in view: NSView, controller: SeamlessController) -> Bool {
        switch state {
        case .idle:
            guard let press = controller.dragOutCandidate() else { return false }
            if let reason = refusal() {
                state = .refused
                DropHUD.shared.show(reason, at: NSEvent.mouseLocation, failed: true)
            } else {
                state = .asking(x: press.x, y: press.y)
                link.queryDragOut(x: press.x, y: press.y)
            }
            cancelGuestDrag()
            return true
        case .asking, .refused, .dragging:
            return true
        case .ready(let paths):
            state = .dragging
            begin(paths: paths, event: event, view: view)
            return true
        }
    }

    /// The button went up. Returns true when drag-out had the drag.
    func released() -> Bool {
        guard isActive else { return false }
        if case .dragging = state { return true }
        state = .idle
        return true
    }

    /// Escape ends the guest's own drag loop without dropping anything; then the button is let go.
    private func cancelGuestDrag() {
        client.sendKey(scancode: 0x01, down: true)
        client.sendKey(scancode: 0x01, down: false)
        input.setButton(.left, down: false)
    }

    private func arrived(_ items: GuestDragOutItems) {
        guard case .asking(let x, let y) = state, x == items.x, y == items.y else { return }
        if items.paths.isEmpty {
            state = .refused
            DropHUD.shared.show(items.message ?? "Nothing to drag to the Mac was selected.", at: NSEvent.mouseLocation, failed: true)
        } else {
            state = .ready(paths: items.paths)
        }
    }

    // MARK: The Mac's drag

    private func begin(paths: [String], event: NSEvent, view: NSView) {
        let items: [NSDraggingItem] = paths.enumerated().map { index, path in
            let name = GuestDragOutItems.fileName(path)
            let ext = (name as NSString).pathExtension
            let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
            provider.userInfo = path
            let item = NSDraggingItem(pasteboardWriter: provider)
            let icon = NSWorkspace.shared.icon(for: type)
            let point = view.convert(event.locationInWindow, from: nil)
            item.setDraggingFrame(NSRect(x: point.x - 24 + CGFloat(index) * 6, y: point.y - 24 - CGFloat(index) * 6, width: 48, height: 48), contents: icon)
            return item
        }
        view.beginDraggingSession(with: items, event: event, source: self)
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Task { @MainActor in self.state = .idle }
    }

    // MARK: File promises

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        GuestDragOutItems.fileName(provider.userInfo as? String ?? "file")
    }

    nonisolated func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { Self.queue }
    private nonisolated static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "tandem.seamless.dragout"
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    /// The drop's destination wants the file: the guest uploads it into the inbox, then it is moved there.
    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let path = provider.userInfo as? String else { completionHandler(VMError("The file is unknown.")); return }
        let fetch = GuestDragOutFetch(id: GuestDragOutFetch.idPrefix + UUID().uuidString.lowercased(), paths: [path])
        // Called on the promise queue; the session's state lives on the main thread.
        let inbox = DispatchQueue.main.sync {
            MainActor.assumeIsolated { () -> URL? in
                let inbox = self.inbox()
                if inbox != nil { self.link.fetchDragOut(fetch) }
                return inbox
            }
        }
        guard let inbox else { completionHandler(VMError("This virtual machine may not send files to the Mac.")); return }
        completionHandler(Self.waitAndMove(fetch, inbox: inbox, to: url))
    }

    /// Waits for the guest's upload to finish (its `.done` file) and moves it to `url`. Large files take a
    /// while; the wait gives up only when the guest stays silent (no new bytes) for two minutes.
    nonisolated static func waitAndMove(_ fetch: GuestDragOutFetch, inbox: URL, to url: URL, silence: TimeInterval = 120) -> Error? {
        let fm = FileManager.default
        let done = inbox.appendingPathComponent(fetch.id + ".done")
        let folder = inbox.appendingPathComponent(fetch.id, isDirectory: true)
        var lastSize: UInt64 = 0
        var lastChange = Date()
        while !fm.fileExists(atPath: done.path) {
            Thread.sleep(forTimeInterval: 0.2)
            let size = FileTransferSize.total(of: folder)
            if size != lastSize { lastSize = size; lastChange = Date() }
            if Date().timeIntervalSince(lastChange) > silence { return VMError("The virtual machine stopped sending the file.") }
        }
        defer { try? fm.removeItem(at: done); try? fm.removeItem(at: folder) }
        let names = (try? String(contentsOf: done, encoding: .utf8))?.split(whereSeparator: \.isNewline).map(String.init) ?? []
        guard let name = names.first else { return VMError("The virtual machine could not send the file.") }
        // The name is the guest's: "../../.ssh/id_ed25519" would move one of the Mac's own files to the drop.
        guard GuestDragOutItems.isPlainName(name) else { return VMError("The virtual machine named the file “\(name)”, which is not a file name.") }
        do {
            try? fm.removeItem(at: url)
            try fm.moveItem(at: folder.appendingPathComponent(name), to: url)
            return nil
        } catch {
            return error
        }
    }
}

/// The bytes below a folder (or of a file), for telling a stalled upload from a slow one.
enum FileTransferSize {
    static func total(of url: URL) -> UInt64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return (try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0 }
        var total: UInt64 = 0
        for case let file as URL in fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) ?? FileManager.DirectoryEnumerator() {
            total += UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
