import Foundation

/// Watches the library's VM folders, so VMs made, copied in or removed by something else (vmctl, the
/// Finder) appear and disappear in the app without a restart. Changes inside a bundle are not reported:
/// only bundles arriving in or leaving a folder. Calls are coalesced, and `onChange` runs on `queue`.
public final class LibraryWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private let queue: DispatchQueue
    private let delay: TimeInterval
    private let onChange: @Sendable () -> Void

    /// `delay`: how long to wait for more changes before reporting, so a bundle being written settles.
    public init(queue: DispatchQueue = .main, delay: TimeInterval = 1.0, onChange: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.delay = delay
        self.onChange = onChange
    }

    deinit { stop() }

    /// Watches these folders (replacing any watched before). Missing folders are skipped.
    public func watch(_ folders: [URL]) {
        stop()
        var made: [DispatchSourceFileSystemObject] = []
        var seen = Set<String>()
        for folder in folders {
            let path = folder.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link], queue: queue)
            source.setEventHandler { [weak self] in self?.changed() }
            source.setCancelHandler { close(fd) }
            source.resume()
            made.append(source)
        }
        lock.lock(); sources = made; lock.unlock()
    }

    public func stop() {
        lock.lock()
        let old = sources; sources = []
        pending?.cancel(); pending = nil
        lock.unlock()
        old.forEach { $0.cancel() }
    }

    /// Reports once, `delay` after the last change.
    private func changed() {
        let item = DispatchWorkItem { [onChange] in onChange() }
        lock.lock()
        pending?.cancel()
        pending = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
