import Darwin
import Foundation

/// Exclusive use of one VM bundle: whoever holds it may run the VM or change its files, and nobody else
/// may until it is released. A run record (`run/host.json`) only describes a run; this is the claim.
///
/// The lease is a `flock` on `.tandem.lock` inside the bundle, held through an open descriptor. The kernel
/// releases it when the descriptor closes, including when the holding process dies, so a crash never
/// leaves a VM locked. `flock` belongs to the open file, not the process: a second lease in the same
/// process (a second engine for one VM, a clone while it runs) is refused just like one from another
/// process. The file starts with a dot, so snapshots, clones and reverts never copy or move it.
public final class BundleLease: @unchecked Sendable {
    public static let fileName = ".tandem.lock"

    /// Who holds a lease, written into the lock file for the message others get.
    public struct Holder: Codable, Equatable, Sendable {
        public var pid: Int32
        public var process: String
        public var purpose: String
        public var since: Date
    }

    public let bundleURL: URL
    public let purpose: String
    private let mutex = NSLock()
    private var descriptor: Int32

    private init(bundleURL: URL, purpose: String, descriptor: Int32) {
        self.bundleURL = bundleURL; self.purpose = purpose; self.descriptor = descriptor
    }

    deinit { release() }

    public var isHeld: Bool { mutex.lock(); defer { mutex.unlock() }; return descriptor >= 0 }

    /// Whether this lease is the claim on `bundle`.
    public func covers(_ bundle: VMBundle) -> Bool {
        isHeld && bundleURL.standardizedFileURL.resolvingSymlinksInPath() == bundle.url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Takes the lease for `purpose` ("running", "cloning", …). Throws a `VMError` naming the holder when
    /// another owner has it. A bundle that has never had a lock file gets one.
    public static func acquire(_ bundle: VMBundle, purpose: String) throws -> BundleLease {
        try acquire(at: bundle.url, name: bundle.config.name, purpose: purpose)
    }

    public static func acquire(at bundleURL: URL, name: String, purpose: String) throws -> BundleLease {
        let path = bundleURL.appendingPathComponent(fileName).path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard fd >= 0 else {
            throw VMError("“\(name)” cannot be used: its lock file cannot be opened.", detail: "\(path): \(String(cString: strerror(errno)))")
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            if error == ENOTSUP || error == EOPNOTSUPP {
                // A volume without file locks (some network shares): run as before, without the claim.
                NSLog("Tandem: the volume of %@ does not support file locks; “%@” runs without an exclusive claim.", bundleURL.path, name)
            } else {
                close(fd)
                if error == EWOULDBLOCK { throw busyError(name: name, holder: holder(at: bundleURL), wanted: purpose) }
                throw VMError("“\(name)” cannot be used: its lock file cannot be locked.", detail: String(cString: strerror(error)))
            }
        }
        let lease = BundleLease(bundleURL: bundleURL, purpose: purpose, descriptor: fd)
        lease.writeHolder()
        return lease
    }

    /// The lease, or nil when someone else holds it.
    public static func tryAcquire(_ bundle: VMBundle, purpose: String) -> BundleLease? {
        try? acquire(bundle, purpose: purpose)
    }

    /// Runs `work` while holding the lease, then releases it.
    public static func with<T>(_ bundle: VMBundle, purpose: String, _ work: (BundleLease) throws -> T) throws -> T {
        let lease = try acquire(bundle, purpose: purpose)
        defer { lease.release() }
        return try work(lease)
    }

    /// Gives the lease up. Harmless when already released. The lock file stays: removing it would let two
    /// owners lock two different files.
    public func release() {
        mutex.lock(); defer { mutex.unlock() }
        guard descriptor >= 0 else { return }
        _ = ftruncate(descriptor, 0)
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    /// What the current holder wrote, if anything.
    public static func holder(at bundleURL: URL) -> Holder? {
        guard let data = try? Data(contentsOf: bundleURL.appendingPathComponent(fileName)), !data.isEmpty else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Holder.self, from: data)
    }

    static func busyError(name: String, holder: Holder?, wanted: String) -> VMError {
        guard let holder else {
            return VMError("“\(name)” is in use by another program.", detail: "Wait until it has finished, or stop the VM there first.")
        }
        if holder.pid == getpid() {
            return VMError("“\(name)” is busy: \(holder.purpose).", detail: "Wait until that has finished, then try again.")
        }
        return VMError("“\(name)” is in use by \(holder.process) (process \(holder.pid)): \(holder.purpose).",
                       detail: "Stop it there first, or quit that program.")
    }

    private func writeHolder() {
        let holder = Holder(pid: getpid(), process: RunRecord.processName(getpid()) ?? "another program", purpose: purpose, since: Date())
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(holder) else { return }
        mutex.lock(); defer { mutex.unlock() }
        guard descriptor >= 0 else { return }
        _ = ftruncate(descriptor, 0)
        _ = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
    }
}

/// Long file work on a bundle (copying, cloning, reverting) away from the caller's actor, so the app stays
/// responsive however slow the disk is. It runs under the bundle's lease: the one the caller already
/// holds (a running VM's engine), or one taken for the duration.
public enum BundleWork {
    public static func run<T: Sendable>(_ bundle: VMBundle, purpose: String, holding lease: BundleLease? = nil,
                                        _ work: @escaping @Sendable () throws -> T) async throws -> T {
        if let lease, !lease.covers(bundle) {
            throw VMError("Internal error: the lease given for “\(bundle.config.name)” is not this VM's.")
        }
        // Taken here, so a VM in use is reported at once rather than from the background.
        let own = lease == nil ? try BundleLease.acquire(bundle, purpose: purpose) : nil
        let task = Task.detached(priority: .userInitiated) { () throws -> T in
            defer { own?.release() }
            try Task.checkCancellation()
            return try work()
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
