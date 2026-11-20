import Foundation

/// A small WebDAV server (RFC 4918 class 1 and 2) that publishes Mac folders to a guest.
///
/// A QEMU guest reaches the Mac's loopback interface at 10.0.2.2, and Windows can open a WebDAV server
/// as a network folder with its built-in WebClient service, so this needs no driver in the guest.
/// The server listens on 127.0.0.1 only. `requiredHost` adds a check on the `Host` header: the guest
/// addresses the server as 10.0.2.2, while a web page in a Mac browser can only reach it under a
/// loopback name, so pages cannot drive it.
///
/// Locks are accepted but not enforced: one guest is the only client, and Windows will not write
/// without them.
public final class WebDAVServer: @unchecked Sendable {
    public struct Share: Equatable, Sendable {
        public var name: String
        public var root: URL
        public var readOnly: Bool
        /// Not listed at the server's root, so a mapped drive does not show it; reachable by name only.
        public var hidden: Bool
        public init(name: String, root: URL, readOnly: Bool = false, hidden: Bool = false) {
            self.name = name; self.root = root.standardizedFileURL; self.readOnly = readOnly; self.hidden = hidden
        }
    }

    private let lock = NSLock()
    private var _shares: [Share]
    private let requiredHost: String?
    private var listener: Int32 = -1
    public private(set) var port: UInt16 = 0
    /// Called with one line per request, for the VM log.
    public var onLog: (@Sendable (String) -> Void)?
    private var _clockSkew: TimeInterval = 0
    /// How far the guest's idea of UTC is ahead of the real one, in seconds. A Windows guest is given
    /// the Mac's wall-clock time whatever its own time zone, so when the zones differ its UTC is off by
    /// the difference. File times are shifted by this on the way out and back, so both sides read the
    /// same wall-clock time.
    public var clockSkew: TimeInterval {
        get { lock.withLock { _clockSkew } }
        set { lock.withLock { _clockSkew = newValue } }
    }

    public init(shares: [Share], requiredHost: String? = "10.0.2.2") {
        _shares = shares
        self.requiredHost = requiredHost
    }

    public var shares: [Share] {
        get { lock.withLock { _shares } }
        set { lock.withLock { _shares = newValue } }
    }

    // MARK: Listening

    /// Starts listening on 127.0.0.1. Port 0 picks a free port. Returns the port in use.
    @discardableResult
    public func start(port requested: UInt16 = 0) throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ShareError("Cannot create a socket: \(String(cString: strerror(errno)))") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requested.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw ShareError("Cannot listen on port \(requested): \(reason)")
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        listener = fd
        port = UInt16(bigEndian: actual.sin_port)
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "tandem.webdav.accept"
        thread.start()
        return port
    }

    public func stop() {
        let fd = lock.withLock { () -> Int32 in let f = listener; listener = -1; return f }
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
    }

    deinit { stop() }

    /// Decides, by the client's local port, whether a connection may be served (nil: any). The owner
    /// uses it to answer the VM's own processes only (`LoopbackPeer`); anything else on the Mac that
    /// finds the port is turned away before a byte is read.
    public var acceptPeer: (@Sendable (_ peerPort: UInt16) -> Bool)? {
        get { lock.withLock { _acceptPeer } }
        set { lock.withLock { _acceptPeer = newValue } }
    }
    private var _acceptPeer: (@Sendable (UInt16) -> Bool)?
    /// Connections served at once; more are closed at once (each one is a thread).
    public static let maxConnections = 64
    private var active = 0

    private func acceptLoop(_ fd: Int32) {
        while true {
            var peer = sockaddr_in()
            var peerLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &peerLength) }
            }
            if client < 0 {
                if errno == EINTR { continue }
                return // listener closed
            }
            let peerPort = UInt16(bigEndian: peer.sin_port)
            if let acceptPeer, !acceptPeer(peerPort) {
                onLog?("refused a connection from port \(peerPort): not this virtual machine")
                close(client)
                continue
            }
            let admitted: Bool = lock.withLock {
                guard active < Self.maxConnections else { return false }
                active += 1
                return true
            }
            guard admitted else { close(client); continue }
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 120, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let thread = Thread { [weak self] in
                let connection = Connection(fd: client)
                while let self, self.serveOne(connection) {}
                close(client)
                if let self { self.lock.withLock { self.active -= 1 } }
            }
            thread.name = "tandem.webdav.client"
            thread.start()
        }
    }

    // MARK: One request

    /// Serves one request. False means the connection should be closed.
    private func serveOne(_ c: Connection) -> Bool {
        guard let request = c.readRequest() else { return false }
        var response: Response
        if let requiredHost, request.header("host")?.split(separator: ":").first.map(String.init) != requiredHost {
            response = Response(status: 403)
        } else {
            response = handle(request, c)
        }
        // Whatever the handler left unread must be consumed, or it would be parsed as the next request.
        guard c.drainBody(of: request) else { return false }
        onLog?("\(request.method) \(request.path) \(response.status)")
        let keepAlive = request.header("connection")?.lowercased() != "close" && response.keepAlive
        return c.send(response, head: request.method == "HEAD", keepAlive: keepAlive) && keepAlive
    }

    private func handle(_ r: Request, _ c: Connection) -> Response {
        guard let target = resolve(r.path) else { return Response(status: 404) }
        switch r.method {
        case "OPTIONS":
            return Response(status: 200, headers: [
                "Allow": "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, COPY, MOVE, PROPFIND, PROPPATCH, LOCK, UNLOCK",
                "DAV": "1, 2", "MS-Author-Via": "DAV",
            ])
        case "PROPFIND": return propfind(r, target)
        case "GET", "HEAD": return get(r, target)
        case "LOCK": return lockResource(r, target)
        case "UNLOCK": return Response(status: 204)
        default: break
        }
        // Everything below changes files.
        guard case .item(let share, let url) = target else { return Response(status: 403) }
        if share.readOnly { return Response(status: 403) }
        let fm = FileManager.default
        switch r.method {
        case "PUT":
            guard url != share.root else { return Response(status: 405) }
            var isDirectory: ObjCBool = false
            let existed = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if existed && isDirectory.boolValue { return Response(status: 405) }
            guard fm.fileExists(atPath: url.deletingLastPathComponent().path) else { return Response(status: 409) }
            // Write beside the target and rename, so a failed upload never leaves half a file in its place.
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".tandem-upload-\(UUID().uuidString.prefix(8))")
            guard fm.createFile(atPath: temporary.path, contents: nil), let handle = try? FileHandle(forWritingTo: temporary) else {
                return Response(status: 403)
            }
            var ok = true
            while let chunk = c.readBodyChunk(of: r) {
                do { try handle.write(contentsOf: chunk) } catch { ok = false; break }
            }
            try? handle.close()
            guard ok, c.bodyComplete(of: r) else { try? fm.removeItem(at: temporary); return Response(status: 507, keepAlive: false) }
            do {
                if existed { _ = try fm.replaceItemAt(url, withItemAt: temporary) } else { try fm.moveItem(at: temporary, to: url) }
            } catch { try? fm.removeItem(at: temporary); return Response(status: 403) }
            return Response(status: existed ? 204 : 201)
        case "DELETE":
            guard url != share.root else { return Response(status: 403) }
            guard fm.fileExists(atPath: url.path) else { return Response(status: 404) }
            do { try fm.removeItem(at: url); return Response(status: 204) } catch { return Response(status: 403) }
        case "MKCOL":
            if fm.fileExists(atPath: url.path) { return Response(status: 405) }
            guard fm.fileExists(atPath: url.deletingLastPathComponent().path) else { return Response(status: 409) }
            do { try fm.createDirectory(at: url, withIntermediateDirectories: false); return Response(status: 201) }
            catch { return Response(status: 403) }
        case "MOVE", "COPY":
            guard url != share.root, fm.fileExists(atPath: url.path) else { return Response(status: 404) }
            guard let destinationHeader = r.header("destination"),
                  let destinationPath = URLComponents(string: destinationHeader)?.percentEncodedPath ?? Optional(destinationHeader),
                  case .item(let toShare, let to)? = resolve(destinationPath), to != toShare.root else { return Response(status: 400) }
            if toShare.readOnly { return Response(status: 403) }
            if to == url { return Response(status: 403) }
            let existed = (try? fm.attributesOfItem(atPath: to.path)) != nil
            if existed, r.header("overwrite")?.uppercased() == "F" { return Response(status: 412) }
            guard fm.fileExists(atPath: to.deletingLastPathComponent().path) else { return Response(status: 409) }
            // A rename that only changes letter case is the same file on a case-insensitive volume.
            let sameFile = existed && (try? fm.attributesOfItem(atPath: to.path)[.systemFileNumber] as? Int)
                == (try? fm.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
            do {
                if !existed || sameFile {
                    if r.method == "MOVE" { try fm.moveItem(at: url, to: to) } else { try fm.copyItem(at: url, to: to) }
                } else {
                    try Self.replace(to, with: url, move: r.method == "MOVE")
                }
                return Response(status: existed ? 204 : 201)
            } catch {
                return Response(status: Self.isOutOfSpace(error) ? 507 : 403)
            }
        case "PROPPATCH":
            guard fm.fileExists(atPath: url.path) else { return Response(status: 404) }
            let body = String(decoding: c.readWholeBody(of: r, limit: 1 << 20) ?? Data(), as: UTF8.self)
            // Windows sets file times this way. Keeping the modification time matters to build tools and sync.
            if let value = Self.xmlValue("Win32LastModifiedTime", in: body), let date = Self.httpDate.date(from: value) {
                try? fm.setAttributes([.modificationDate: date.addingTimeInterval(-clockSkew)], ofItemAtPath: url.path)
            }
            return Response.multistatus("<D:response><D:href>\(Self.href(r.path))</D:href><D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>")
        default:
            return Response(status: 405)
        }
    }

    // MARK: Replacing

    /// Puts `source` (moved or copied) where `destination` is, keeping the old destination until the
    /// new one is in place: a failed copy or move leaves both as they were.
    ///
    /// - MOVE on one volume: one atomic swap of source and destination, then the old destination (now at
    ///   the source's path) is removed.
    /// - Otherwise: a full copy into a hidden sibling of the destination, an atomic swap with the
    ///   destination, then removal of the old destination and, for MOVE, of the source.
    static func replace(_ destination: URL, with source: URL, move: Bool, fileManager fm: FileManager = .default) throws {
        if move, renamex_np(source.path, destination.path, UInt32(RENAME_SWAP)) == 0 {
            try? fm.removeItem(at: source)
            return
        }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".tandem-upload-\(UUID().uuidString.prefix(8))")
        do {
            try fm.copyItem(at: source, to: staged)
        } catch {
            // A copy that failed half way (out of space) must not leave its part behind.
            try? fm.removeItem(at: staged)
            throw error
        }
        do {
            try commit(staged, over: destination, fileManager: fm)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        if move { try? fm.removeItem(at: source) }
    }

    /// Swaps `staged` into `destination`'s place and removes the old destination. Where the volume
    /// cannot swap, the old destination is renamed aside first and put back if the new one cannot go in.
    static func commit(_ staged: URL, over destination: URL, fileManager fm: FileManager = .default) throws {
        if renamex_np(staged.path, destination.path, UInt32(RENAME_SWAP)) == 0 {
            try? fm.removeItem(at: staged)   // now holds the old destination
            return
        }
        let aside = destination.deletingLastPathComponent().appendingPathComponent(".tandem-upload-old-\(UUID().uuidString.prefix(8))")
        try fm.moveItem(at: destination, to: aside)
        do {
            try fm.moveItem(at: staged, to: destination)
        } catch {
            try? fm.moveItem(at: aside, to: destination)
            throw error
        }
        try? fm.removeItem(at: aside)
    }

    static func isOutOfSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isOutOfSpace(underlying) }
        return false
    }

    // MARK: Paths

    enum Target {
        case root
        case item(Share, URL)
    }

    /// Maps a request path to a location inside a share. Nil for anything that is not inside one.
    func resolve(_ rawPath: String) -> Target? {
        let pathOnly = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawPath
        guard let decoded = pathOnly.removingPercentEncoding else { return nil }
        let parts = decoded.split(separator: "/").map(String.init)
        // No ".." at all: nothing legitimate needs it, and it is the only way out of a share.
        guard !parts.contains(".."), !parts.contains(where: { $0.contains("\0") }) else { return nil }
        guard let first = parts.first else { return .root }
        guard let share = shares.first(where: { $0.name.compare(first, options: .caseInsensitive) == .orderedSame }) else { return nil }
        var url = share.root
        let below = parts.dropFirst().filter { $0 != "." }
        for part in below { url.appendPathComponent(part) }
        // A symbolic link inside the share may point anywhere on the Mac: refuse any path whose links
        // lead out of the share (or nowhere). Links that stay inside keep working.
        guard Self.staysInside(share.root, below) else { return nil }
        return .item(share, url)
    }

    /// True when following `components` from `root`, link by link, never leaves `root`. A name that does
    /// not exist yet ends the walk (nothing below it can exist either). A link whose target is missing
    /// is refused: creating a file through it would create it wherever it points.
    ///
    /// This is canonicalise-then-use, so a link swapped in between could still be followed. Only programs
    /// on the Mac can make links in a share (WebDAV has no way to create one), and they already have the
    /// user's rights, so the gap gives a guest nothing.
    static func staysInside(_ root: URL, _ components: [String]) -> Bool {
        guard let canonicalRoot = realPath(root.path) else { return components.isEmpty }
        var current = canonicalRoot
        for component in components {
            let candidate = current + "/" + component
            var info = stat()
            guard lstat(candidate, &info) == 0 else {
                // Missing: the rest is a new name below a folder already checked.
                return errno == ENOENT || errno == ENOTDIR
            }
            if info.st_mode & S_IFMT == S_IFLNK {
                guard let target = realPath(candidate), isWithin(target, canonicalRoot) else { return false }
                current = target
            } else {
                current = candidate
            }
        }
        return true
    }

    /// Whether `url` (an existing item, typically a directory listing's child) stays inside `root`.
    static func isInside(_ url: URL, root: URL) -> Bool {
        guard let canonicalRoot = realPath(root.path), let target = realPath(url.path) else { return false }
        return isWithin(target, canonicalRoot)
    }

    private static func isWithin(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func href(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "&<>\"'%;?#")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    // MARK: Reading

    private func get(_ r: Request, _ target: Target) -> Response {
        guard case .item(_, let url) = target else {
            return Response(status: 200, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data("Tandem shared folders\n".utf8))
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return Response(status: 404) }
        if isDirectory.boolValue {
            return Response(status: 200, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data("Folder\n".utf8))
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64, let handle = try? FileHandle(forReadingFrom: url) else { return Response(status: 403) }
        var headers = ["Content-Type": "application/octet-stream", "Accept-Ranges": "bytes",
                       "Last-Modified": Self.httpDate.string(from: ((attributes[.modificationDate] as? Date) ?? Date()).addingTimeInterval(clockSkew)),
                       "ETag": Self.etag(attributes)]
        var range: Range<UInt64> = 0..<size
        var status = 200
        if let header = r.header("range"), header.hasPrefix("bytes="), !header.contains(",") {
            let bounds = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            // A last byte before the first makes the range invalid, and an invalid range is ignored
            // (RFC 9110 §14.2): the whole file is sent. (It used to build a backwards Range and trap.)
            let start = bounds.count == 2 ? UInt64(bounds[0]) : nil, end = bounds.count == 2 ? UInt64(bounds[1]) : nil
            let backwards = start != nil && end != nil && end! < start!
            if bounds.count == 2, !backwards {
                if let start, start < size {
                    // min first: `end + 1` overflows for an end of UInt64.max.
                    range = start..<(min(end ?? size - 1, size - 1) + 1)
                } else if start == nil, let suffix = end, suffix > 0, size > 0 {
                    // Not for an empty file: the Content-Range below would count down from 0 and trap.
                    range = (size - min(size, suffix))..<size
                } else {
                    try? handle.close()
                    return Response(status: 416, headers: ["Content-Range": "bytes */\(size)"])
                }
                status = 206
                headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(size)"
            }
        }
        return Response(status: status, headers: headers, file: handle, fileRange: range)
    }

    private func propfind(_ r: Request, _ target: Target) -> Response {
        let skew = clockSkew
        let depthOne = r.header("depth") != "0"
        let base = r.path.split(separator: "?").first.map(String.init) ?? "/"
        let prefix = base.hasSuffix("/") ? base : base + "/"
        var xml = ""
        switch target {
        case .root:
            xml += Self.entry(href: "/", name: "", attributes: nil, isDirectory: true, freeBytes: nil, skew: skew)
            if depthOne {
                for share in shares where !share.hidden {
                    xml += Self.entry(href: "/" + share.name + "/", name: share.name,
                                      attributes: try? FileManager.default.attributesOfItem(atPath: share.root.path),
                                      isDirectory: true, freeBytes: Self.freeBytes(share.root), skew: skew)
                }
            }
        case .item(let share, let url):
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return Response(status: 404) }
            let own = try? FileManager.default.attributesOfItem(atPath: url.path)
            xml += Self.entry(href: isDirectory.boolValue ? prefix : base, name: url.lastPathComponent, attributes: own,
                              isDirectory: isDirectory.boolValue, freeBytes: isDirectory.boolValue ? Self.freeBytes(url) : nil, skew: skew)
            if depthOne && isDirectory.boolValue {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
                for name in names.sorted() where !name.hasPrefix(".tandem-upload-") {
                    let child = url.appendingPathComponent(name)
                    // A link that leads out of the share is not shown (it could not be opened either).
                    guard Self.isInside(child, root: share.root) else { continue }
                    // Follow links, so a link to a folder opens as a folder.
                    var childIsDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: child.path, isDirectory: &childIsDirectory) else { continue }
                    let attributes = try? FileManager.default.attributesOfItem(atPath: child.resolvingSymlinksInPath().path)
                    xml += Self.entry(href: prefix + name + (childIsDirectory.boolValue ? "/" : ""), name: name,
                                      attributes: attributes, isDirectory: childIsDirectory.boolValue, freeBytes: nil, skew: skew)
                }
            }
        }
        return Response.multistatus(xml)
    }

    private func lockResource(_ r: Request, _ target: Target) -> Response {
        var status = 200
        if case .item(let share, let url) = target, !FileManager.default.fileExists(atPath: url.path) {
            // Locking a name that does not exist reserves it as an empty file (RFC 4918 §9.10.4).
            guard !share.readOnly, FileManager.default.createFile(atPath: url.path, contents: nil) else { return Response(status: 403) }
            status = 201
        }
        let token = "opaquelocktoken:" + UUID().uuidString.lowercased()
        let body = """
        <?xml version="1.0" encoding="utf-8"?><D:prop xmlns:D="DAV:"><D:lockdiscovery><D:activelock>\
        <D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope><D:depth>infinity</D:depth>\
        <D:timeout>Second-3600</D:timeout><D:locktoken><D:href>\(token)</D:href></D:locktoken>\
        <D:lockroot><D:href>\(Self.href(r.path))</D:href></D:lockroot></D:activelock></D:lockdiscovery></D:prop>
        """
        return Response(status: status, headers: ["Content-Type": "application/xml; charset=utf-8", "Lock-Token": "<\(token)>"], body: Data(body.utf8))
    }

    // MARK: XML

    static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    private static let isoDate: ISO8601DateFormatter = ISO8601DateFormatter()

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func etag(_ attributes: [FileAttributeKey: Any]) -> String {
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\"\(String(Int(modified * 1000), radix: 16))-\(String((attributes[.size] as? UInt64) ?? 0, radix: 16))\""
    }

    private static func freeBytes(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    private static func entry(href path: String, name: String, attributes: [FileAttributeKey: Any]?, isDirectory: Bool, freeBytes: Int64?, skew: TimeInterval) -> String {
        let modified = ((attributes?[.modificationDate] as? Date) ?? Date()).addingTimeInterval(skew)
        let created = (attributes?[.creationDate] as? Date).map { $0.addingTimeInterval(skew) } ?? modified
        var props = "<D:displayname>\(escape(name))</D:displayname>"
        props += "<D:getlastmodified>\(httpDate.string(from: modified))</D:getlastmodified>"
        props += "<D:creationdate>\(isoDate.string(from: created))</D:creationdate>"
        if isDirectory {
            props += "<D:resourcetype><D:collection/></D:resourcetype>"
            if let freeBytes { props += "<D:quota-available-bytes>\(freeBytes)</D:quota-available-bytes>" }
        } else {
            props += "<D:resourcetype/><D:getcontentlength>\((attributes?[.size] as? UInt64) ?? 0)</D:getcontentlength>"
            props += "<D:getcontenttype>application/octet-stream</D:getcontenttype>"
            if let attributes { props += "<D:getetag>\(escape(etag(attributes)))</D:getetag>" }
        }
        props += "<D:supportedlock><D:lockentry><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockentry></D:supportedlock>"
        return "<D:response><D:href>\(href(path))</D:href><D:propstat><D:prop>\(props)</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
    }

    /// Text of the first element whose local name is `name`, whatever its namespace prefix.
    static func xmlValue(_ name: String, in xml: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<(?:[A-Za-z0-9]+:)?\(name)[^>]*>([^<]*)</", options: []),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else { return nil }
        return String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct ShareError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - HTTP plumbing

struct Request {
    var method: String
    var path: String
    var headers: [String: String]
    func header(_ name: String) -> String? { headers[name] }
    var contentLength: Int? { header("content-length").flatMap { Int($0) } }
    var chunked: Bool { header("transfer-encoding")?.lowercased().contains("chunked") == true }
}

struct Response {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
    var file: FileHandle?
    var fileRange: Range<UInt64> = 0..<0
    var keepAlive = true

    static func multistatus(_ inner: String) -> Response {
        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:multistatus xmlns:D=\"DAV:\">\(inner)</D:multistatus>"
        return Response(status: 207, headers: ["Content-Type": "application/xml; charset=utf-8"], body: Data(xml.utf8))
    }

    static let reasons: [Int: String] = [
        200: "OK", 201: "Created", 204: "No Content", 206: "Partial Content", 207: "Multi-Status", 400: "Bad Request",
        403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 412: "Precondition Failed",
        416: "Range Not Satisfiable", 507: "Insufficient Storage",
    ]
}

/// One client socket: buffered request parsing and streamed bodies.
final class Connection {
    let fd: Int32
    private var buffer = Data()
    /// Body bytes of the current request still to be read (fixed length), or nil when chunked.
    private var remaining = 0
    private var chunkedDone = false
    private var failed = false

    init(fd: Int32) { self.fd = fd }

    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = recv(fd, &chunk, chunk.count, 0)
        guard n > 0 else { return false }
        buffer.append(contentsOf: chunk[0..<n])
        return true
    }

    func readRequest() -> Request? {
        let terminator = Data("\r\n\r\n".utf8)
        var end = buffer.range(of: terminator)
        while end == nil {
            guard buffer.count < 64 * 1024, fill() else { return nil }
            end = buffer.range(of: terminator)
        }
        guard let end, let head = String(data: buffer.subdata(in: buffer.startIndex..<end.lowerBound), encoding: .utf8) else { return nil }
        buffer.removeSubrange(buffer.startIndex..<end.upperBound)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var path = String(requestLine[1])
        // A proxy-style absolute URL: keep only the path.
        if path.lowercased().hasPrefix("http"), let components = URLComponents(string: path) { path = components.percentEncodedPath }
        let request = Request(method: String(requestLine[0]).uppercased(), path: path.isEmpty ? "/" : path, headers: headers)
        // A length that is not a number of bytes cannot be read past: give up on the connection.
        if let length = request.header("content-length"), (Int(length) ?? -1) < 0 { return nil }
        remaining = request.contentLength ?? 0
        chunkedDone = !request.chunked
        failed = false
        if request.header("expect")?.lowercased() == "100-continue" { _ = sendAll(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) }
        return request
    }

    private func readLine() -> String? {
        let crlf = Data("\r\n".utf8)
        while true {
            if let r = buffer.range(of: crlf) {
                let line = String(decoding: buffer.subdata(in: buffer.startIndex..<r.lowerBound), as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                return line
            }
            guard buffer.count < 8192, fill() else { return nil }
        }
    }

    private func take(_ count: Int) -> Data? {
        if buffer.isEmpty, !fill() { return nil }
        let n = min(count, buffer.count)
        let data = buffer.prefix(n)
        buffer.removeFirst(n)
        return Data(data)
    }

    /// Next piece of the request body, nil at its end or on failure (see `bodyComplete`).
    func readBodyChunk(of request: Request) -> Data? {
        if failed { return nil }
        if request.chunked {
            if chunkedDone { return nil }
            if remaining == 0 {
                // A negative size ("-1") used to reach `prefix(-1)` and trap.
                guard let sizeLine = readLine(), let size = Int(sizeLine.split(separator: ";").first ?? "", radix: 16), size >= 0 else {
                    failed = true; return nil
                }
                if size == 0 {
                    while let trailer = readLine(), !trailer.isEmpty {}
                    chunkedDone = true
                    return nil
                }
                remaining = size
            }
            guard let data = take(min(remaining, 256 * 1024)) else { failed = true; return nil }
            remaining -= data.count
            if remaining == 0 { _ = readLine() } // the CRLF after the chunk
            return data
        }
        guard remaining > 0 else { return nil }
        guard let data = take(min(remaining, 256 * 1024)) else { failed = true; return nil }
        remaining -= data.count
        return data
    }

    func bodyComplete(of request: Request) -> Bool { !failed && remaining == 0 && chunkedDone }

    func readWholeBody(of request: Request, limit: Int) -> Data? {
        var body = Data()
        while let chunk = readBodyChunk(of: request) {
            body.append(chunk)
            if body.count > limit { return nil }
        }
        return bodyComplete(of: request) ? body : nil
    }

    func drainBody(of request: Request) -> Bool {
        while readBodyChunk(of: request) != nil {}
        return bodyComplete(of: request)
    }

    private func sendAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    func send(_ response: Response, head: Bool, keepAlive: Bool) -> Bool {
        defer { try? response.file?.close() }
        let length = response.file != nil ? Int(response.fileRange.upperBound - response.fileRange.lowerBound) : response.body.count
        var text = "HTTP/1.1 \(response.status) \(Response.reasons[response.status] ?? "Status")\r\n"
        var headers = response.headers
        headers["Content-Length"] = "\(length)"
        headers["Connection"] = keepAlive ? "keep-alive" : "close"
        headers["Date"] = WebDAVServer.httpDate.string(from: Date())
        headers["Server"] = "Tandem"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        guard sendAll(Data(text.utf8)) else { return false }
        if head { return true }
        guard let file = response.file else { return sendAll(response.body) }
        do {
            try file.seek(toOffset: response.fileRange.lowerBound)
            var left = length
            while left > 0 {
                guard let chunk = try file.read(upToCount: min(left, 256 * 1024)), !chunk.isEmpty else { return false }
                guard sendAll(chunk) else { return false }
                left -= chunk.count
            }
            return true
        } catch { return false }
    }
}
