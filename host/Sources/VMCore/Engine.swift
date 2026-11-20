import Foundation

/// A bidirectional byte stream to the guest agent, whatever the transport (vsock, virtio-serial).
public protocol GuestStream: AnyObject, Sendable {
    /// Reads up to `max` bytes. Returns empty data at end of stream.
    func read(max: Int) throws -> Data
    /// Like `read(max:)`, but returns nil if nothing arrives within `timeout` seconds.
    func read(max: Int, timeout: TimeInterval) throws -> Data?
    func write(_ data: Data) throws
    func close()
}

/// The one interface between the app and a virtualization backend.
@MainActor
public protocol VMEngine: AnyObject {
    var kind: EngineKind { get }
    var lifecycle: LifecycleMachine { get }
    /// The claim on the VM's bundle, held from the start of `start()` until the VM has stopped. Work on
    /// the bundle while it runs (a snapshot) goes under this lease.
    var bundleLease: BundleLease? { get }

    func start() async throws
    func pause() async throws
    func resume() async throws
    /// Asks the guest to shut down (ACPI power button or equivalent).
    func requestStop() async throws
    /// Saves the running VM's memory and devices into the bundle and stops it. The next `start` resumes from there.
    func suspend() async throws
    /// Saves the running VM's memory and devices into the bundle and leaves it paused, so that the bundle can
    /// be copied as a snapshot. Follow with `finishSnapshot()`.
    func prepareSnapshot() async throws
    /// Removes the state written by `prepareSnapshot()` and lets the VM run on, if it was running before;
    /// a VM the user had paused stays paused (`SnapshotPause`).
    func finishSnapshot() async throws
    /// Stops immediately. Guest data may be lost.
    func forceStop() async throws

    /// Called for every guest-agent stream the guest opens.
    var onGuestStream: (@Sendable (GuestStream) -> Void)? { get set }
}

/// What a snapshot of a live VM must put back: an engine pauses the VM to write its state, and lets it run
/// on afterwards only if it was running. Taking a snapshot must not wake a VM the user paused.
public struct SnapshotPause: Equatable, Sendable {
    public let resumeAfterwards: Bool
    public init(stateBefore: VMState) { resumeAfterwards = stateBefore == .running }
    /// The state the VM should be in once the snapshot is done.
    public var stateAfterwards: VMState { resumeAfterwards ? .running : .paused }
}
