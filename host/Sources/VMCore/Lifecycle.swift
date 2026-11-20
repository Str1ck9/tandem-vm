import Foundation

/// Runtime state of a VM. Not persisted.
public enum VMState: String, Sendable, CaseIterable {
    case stopped, starting, running, paused, stopping, error

    /// States this state may move to.
    public var allowedNext: Set<VMState> {
        switch self {
        case .stopped: return [.starting]
        case .starting: return [.running, .stopped, .error]
        case .running: return [.paused, .stopping, .stopped, .error]
        case .paused: return [.running, .stopping, .stopped, .error]
        case .stopping: return [.stopped, .error]
        case .error: return [.starting, .stopped]
        }
    }

    public func canTransition(to next: VMState) -> Bool { allowedNext.contains(next) }

    public var isActive: Bool { self != .stopped && self != .error }
}

public enum VMAction: String, Sendable, CaseIterable {
    case start, pause, resume, stop, forceStop

    /// States in which the action is offered to the user.
    public var validFrom: Set<VMState> {
        switch self {
        case .start: return [.stopped, .error]
        case .pause: return [.running]
        case .resume: return [.paused]
        case .stop: return [.running, .paused]
        case .forceStop: return [.starting, .running, .paused, .stopping]
        }
    }
}

public struct VMError: Error, LocalizedError, Equatable, Sendable {
    public var message: String
    public var detail: String?
    public init(_ message: String, detail: String? = nil) { self.message = message; self.detail = detail }
    public var errorDescription: String? { detail.map { "\(message)\n\($0)" } ?? message }
}

/// Holds the current state and rejects illegal transitions.
public final class LifecycleMachine: @unchecked Sendable {
    private let lock = NSLock()
    private var _state: VMState = .stopped
    private var _lastError: VMError?
    public var onChange: (@Sendable (VMState) -> Void)?

    public init() {}

    public var state: VMState { lock.withLock { _state } }
    public var lastError: VMError? { lock.withLock { _lastError } }

    /// Moves to `next`. Returns false (and changes nothing) if the transition is not allowed.
    @discardableResult
    public func transition(to next: VMState, error: VMError? = nil) -> Bool {
        let ok: Bool = lock.withLock {
            guard _state.canTransition(to: next) else { return false }
            _state = next
            _lastError = next == .error ? error : nil
            return true
        }
        if ok { onChange?(next) }
        return ok
    }

    public func can(_ action: VMAction) -> Bool { action.validFrom.contains(state) }
}
