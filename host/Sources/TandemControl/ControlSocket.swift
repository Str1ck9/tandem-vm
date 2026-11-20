import Darwin
import Foundation

/// The unix-socket plumbing both ends of the control API share.
public enum ControlSocket {
    /// `sockaddr_un` for a path, or nil when the path is too long for one (104 bytes on macOS).
    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// Opens a connection; nil when nothing listens there.
    public static func connect(path: String) -> Int32? {
        guard var addr = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 { close(fd); return nil }
        return fd
    }

    /// Creates a listening socket only this user can use. Replaces a stale socket file.
    public static func listen(path: String) throws -> Int32 {
        guard var addr = address(path) else { throw ControlError.failed("The control socket path is too long: \(path)") }
        // A socket file nobody answers on is left over from a process that ended; one that answers is a
        // second app on the same library, which must not be taken over.
        if FileManager.default.fileExists(atPath: path) {
            if let other = connect(path: path) { close(other); throw ControlError("unavailable", "Another Tandem is already serving this library.", detail: path) }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.failed("Could not create the control socket.", detail: String(cString: strerror(errno))) }
        let old = umask(0o077)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(old)
        guard bound == 0 else {
            let message = String(cString: strerror(errno)); close(fd)
            throw ControlError.failed("Could not open the control socket.", detail: "\(path): \(message)")
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else { close(fd); throw ControlError.failed("Could not listen on the control socket.") }
        return fd
    }

    /// True when the process at the other end runs as this user.
    public static func peerIsSameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    // MARK: Lines

    /// Reads one newline-terminated line (without the newline). Nil at end of stream. Lines over `limit` fail.
    public static func readLine(_ fd: Int32, buffer: inout Data, limit: Int = 64 << 20) -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            if buffer.count > limit { return nil }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(chunk, count: n)
        }
    }

    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { if errno == EINTR { continue }; return false }
                offset += n
            }
            return true
        }
    }
}

/// A connection from a client (the `tandem` command or its MCP server) to the app.
public final class ControlConnection {
    private let fd: Int32
    private var buffer = Data()
    private var nextID = 1
    public let client: ControlClient

    public init(fd: Int32, client: ControlClient) { self.fd = fd; self.client = client }
    deinit { close(fd) }

    /// Connects to the app serving `libraryRoot`; nil when it is not running.
    public static func open(libraryRoot: URL, client: ControlClient) -> ControlConnection? {
        ControlSocket.connect(path: ControlProtocol.socketURL(libraryRoot: libraryRoot).path).map { ControlConnection(fd: $0, client: client) }
    }

    /// Sends one request and waits for its answer.
    public func send(_ op: ControlOp, vm: String? = nil, args: [String: JSON] = [:]) throws -> JSON {
        let request = ControlRequest(id: nextID, client: client, op: op, vm: vm, args: args)
        nextID += 1
        guard ControlSocket.writeAll(fd, try ControlCoding.encode(request)) else {
            throw ControlError("unavailable", "The connection to Tandem was lost.")
        }
        guard let line = ControlSocket.readLine(fd, buffer: &buffer) else {
            throw ControlError("unavailable", "Tandem closed the connection before answering.")
        }
        let response = try ControlCoding.decode(ControlResponse.self, line: line)
        if let error = response.error { throw error }
        return response.result ?? .null
    }
}
