import Foundation
import VMCore

/// Makes `<vm>.tandem.test` resolve on this Mac.
///
/// Every published service listens on the Mac itself, so every name under `tandem.test` has the same
/// answer: 127.0.0.1. Two pieces make the Mac ask:
///   1. a tiny DNS responder on a fixed loopback port, run by whichever Tandem process has VMs running
///      (this file; needs no rights);
///   2. the file `/etc/resolver/tandem.test`, which tells macOS to send questions about that domain to
///      the responder. Writing it needs an administrator once (`installCommand`); Tandem never does it itself.
/// Without the file the names do not resolve, and services are reached as `localhost:<port>` or
/// `<vm>.localhost:<port>` (browsers and curl treat names under `localhost` as this Mac).
public enum LocalNames {
    /// Loopback port of the responder. Unprivileged, and outside the range services are given.
    public static let port = 53535
    public static let resolverFile = "/etc/resolver/" + PublishedServices.domain

    public static var resolverFileContents: String { "# Tandem: names of published guest services\nnameserver 127.0.0.1\nport \(port)\n" }

    /// The one command an administrator runs to switch the names on.
    public static var installCommand: String {
        "sudo sh -c 'mkdir -p /etc/resolver && printf \"nameserver 127.0.0.1\\nport \(port)\\n\" > \(resolverFile)'"
    }

    /// True when macOS has been told to ask Tandem about `tandem.test`.
    public static var isInstalled: Bool {
        guard let text = try? String(contentsOfFile: resolverFile, encoding: .utf8) else { return false }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.contains("nameserver 127.0.0.1") && lines.contains("port \(port)")
    }

    /// The address to show for a service: the stable name when it resolves, the loopback name otherwise.
    public static func address(for service: PublishedService, vmName: String, namesInstalled: Bool = LocalNames.isInstalled) -> String {
        (namesInstalled ? PublishedServices.hostName(forVMNamed: vmName) : PublishedServices.loopbackName(forVMNamed: vmName)) + ":\(service.hostPort)"
    }

    // MARK: DNS answers

    /// Answers one DNS question. Names under `tandem.test` get 127.0.0.1 for an address (A) question and
    /// an empty answer for other kinds; anything else is refused. Nil for datagrams that are not questions.
    public static func response(to query: Data) -> Data? {
        let q = [UInt8](query)
        // Header: id, flags, counts. One question, a query, not a response.
        guard q.count >= 17, q[2] & 0x80 == 0, (Int(q[4]) << 8 | Int(q[5])) == 1 else { return nil }
        var labels: [String] = []
        var i = 12
        while i < q.count, q[i] != 0 {
            let length = Int(q[i])
            guard length < 64, i + 1 + length <= q.count else { return nil } // compression is not valid in a question
            labels.append(String(decoding: q[(i + 1)..<(i + 1 + length)], as: UTF8.self).lowercased())
            i += 1 + length
        }
        guard i + 5 <= q.count else { return nil }
        let questionEnd = i + 5
        let type = Int(q[i + 1]) << 8 | Int(q[i + 2]), qclass = Int(q[i + 3]) << 8 | Int(q[i + 4])
        let ours = labels.count >= 2 && labels.suffix(2).joined(separator: ".") == PublishedServices.domain
        let answers = ours && type == 1 && qclass == 1
        // id, flags (response, authoritative, recursion desired copied; REFUSED for names that are not ours).
        var out: [UInt8] = [q[0], q[1], 0x84 | (q[2] & 0x01), ours ? 0x00 : 0x05, 0, 1, 0, answers ? 1 : 0, 0, 0, 0, 0]
        out += q[12..<questionEnd]
        if answers {
            // A pointer to the name in the question, type A, class IN, TTL 5 s, four bytes: 127.0.0.1.
            out += [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 5, 0, 4, 127, 0, 0, 1]
        }
        return Data(out)
    }

    // MARK: Responder

    private static let lock = NSLock()
    nonisolated(unsafe) private static var socketFD: Int32 = -1

    /// Starts answering on 127.0.0.1:`port`. Harmless to call again. Returns false when another Tandem
    /// process already answers there, which is just as good: all of them give the same answer.
    @discardableResult
    public static func startResponder() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if socketFD >= 0 { return true }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { close(fd); return false }
        socketFD = fd
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 1500)
            while true {
                var from = sockaddr_storage()
                var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let count = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) } }
                if count < 0 { if errno == EINTR { continue }; return }
                guard let answer = response(to: Data(buffer[0..<count])) else { continue }
                _ = answer.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes.baseAddress, bytes.count, 0, $0, length) } }
                }
            }
        }
        thread.name = "tandem.localnames"
        thread.start()
        return true
    }
}
