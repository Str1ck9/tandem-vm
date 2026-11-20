import Foundation

/// A `GuestStream` over a POSIX file descriptor (vsock connection or unix socket).
public final class FDStream: GuestStream, @unchecked Sendable {
    private let fd: Int32
    private let owner: AnyObject?
    private let lock = NSLock()
    private var closed = false

    /// `owner` is retained for the life of the stream (for example the VZ connection object that owns `fd`).
    public init(fileDescriptor: Int32, owner: AnyObject? = nil) {
        self.fd = fileDescriptor; self.owner = owner
    }

    public func read(max: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: max)
        while true {
            let n = Darwin.read(fd, &buffer, max)
            if n >= 0 { return Data(buffer[0..<n]) }
            if errno == EINTR { continue }
            throw VMError("Guest stream read failed.", detail: String(cString: strerror(errno)))
        }
    }

    public func read(max: Int, timeout: TimeInterval) throws -> Data? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            let n = poll(&pfd, 1, Int32(timeout * 1000))
            if n > 0 { return try read(max: max) }
            if n == 0 { return nil }
            if errno != EINTR { throw VMError("Guest stream poll failed.", detail: String(cString: strerror(errno))) }
        }
    }

    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw VMError("Guest stream write failed.", detail: String(cString: strerror(errno)))
                }
                offset += n
            }
        }
    }

    public func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            Darwin.shutdown(fd, SHUT_RDWR)
            if owner == nil { Darwin.close(fd) }
        }
    }
}
