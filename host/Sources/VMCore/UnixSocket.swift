import Foundation

public enum UnixSocket {
    /// Longest path that fits in `sockaddr_un.sun_path` (including the terminator).
    public static let maxPathLength = 103

    /// Connects to a unix stream socket and returns the file descriptor.
    public static func connect(path: String) throws -> Int32 {
        guard path.utf8.count <= maxPathLength else { throw VMError("Socket path is too long (\(path.utf8.count) bytes): \(path)") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VMError("socket() failed.", detail: String(cString: strerror(errno))) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: path.utf8.prefix(raw.count - 1))
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw VMError("Cannot connect to \(path).", detail: reason)
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Retries `connect` until it succeeds or the deadline passes. The socket may not exist yet.
    public static func connect(path: String, timeout: TimeInterval) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do { return try connect(path: path) }
            catch {
                if Date() >= deadline { throw error }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
}
