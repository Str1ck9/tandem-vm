import Darwin
import Foundation

/// Who is at the other end of a loopback TCP connection.
///
/// A server on 127.0.0.1 can be reached by every process on the Mac, other users' included. A VM's
/// share server should answer its VM only: the guest's connections arrive from the VM's QEMU process
/// (its user-mode network) or from the `nc` it starts for each connection (`guestfwd`), so the server
/// accepts a connection only when one of those processes holds the other end.
public enum LoopbackPeer {
    /// True when `pid`, or one of its direct children, has a TCP socket from local port `peerPort` to
    /// port `serverPort`: the client end of a connection the server accepted.
    public static func connection(fromPort peerPort: UInt16, toPort serverPort: UInt16, isHeldByProcessOrChildOf pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if process(pid, holds: peerPort, serverPort) { return true }
        if children(of: pid).contains(where: { process($0, holds: peerPort, serverPort) }) { return true }
        // libslirp starts guestfwd's `nc` through GLib, which puts an intermediate process in between and
        // so leaves nc a child of launchd. Such an nc of this user's counts as the VM's too.
        return forwarders(of: pid).contains { process($0, holds: peerPort, serverPort) }
    }

    /// This user's `/usr/bin/nc` processes whose parent is launchd, `pid`, or GLib's intermediate
    /// process (a child of `pid`) in the moment before it exits.
    static func forwarders(of pid: pid_t) -> [pid_t] {
        let uid = getuid()
        let parents = Set([1, pid] + children(of: pid))
        var buffer = [pid_t](repeating: 0, count: 4096)
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), uid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return buffer.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { candidate in
            guard candidate > 1 else { return false }
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(candidate, &path, UInt32(path.count)) > 0, String(cString: path) == "/usr/bin/nc" else { return false }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(candidate, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
            return info.pbi_uid == uid && parents.contains(pid_t(info.pbi_ppid))
        }
    }

    static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return Array(buffer.prefix(Int(count))).filter { $0 > 0 }
    }

    /// Whether process `pid` has a TCP socket bound to `localPort` and connected to `remotePort`.
    static func process(_ pid: pid_t, holds localPort: UInt16, _ remotePort: UInt16) -> Bool {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return false }
        let capacity = Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 32
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(capacity * MemoryLayout<proc_fdinfo>.stride))
        guard used > 0 else { return false }
        for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let inet = info.psi.soi_proto.pri_tcp.tcpsi_ini
            let local = UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport))
            let remote = UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_fport))
            if local == localPort && remote == remotePort { return true }
        }
        return false
    }
}
