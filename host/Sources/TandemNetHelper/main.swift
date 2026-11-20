// Tandem helper: a small root daemon for the two things macOS reserves for root (or for apps with a
// restricted entitlement): bridged networking and taking USB devices away from macOS's own drivers.
//
// Bridged networking: the helper creates a vmnet interface on request and relays raw Ethernet frames
// between it and a unix datagram socket that the VM (QEMU's `-netdev dgram`, or a file-handle network
// attachment) talks to.
// USB: the helper runs usbredir's `usbredirect` as root for one device (root lets libusb detach macOS's
// driver), and relays its usbredir stream to a unix socket that only the allowed user can open; QEMU's
// `usb-redir` device connects there. When the stream ends, usbredirect exits and macOS gets the device back.
//
// Control protocol on the stream socket: one JSON object per line in, one per line out.
//   {"op":"version"}                              → {"ok":true,"version":2,"features":["bridge","usb"]}
//   {"op":"interfaces"}                           → {"ok":true,"interfaces":["en0"]}
//   {"op":"bridge","interface":"en0","peer":"…"}  → {"ok":true,"socket":"…","mtu":1500,"maxPacketSize":1514}
//   {"op":"usb","vendor":4660,"product":22136,"location":35651584}
//                                                 → {"ok":true,"socket":"…"}  (a unix stream socket)
//   {"op":"disk","bsd":"disk4"}                   → {"ok":true,"socket":"…","readOnly":false,"size":…}
//                                                   (the disk is unmounted and served over NBD on that socket)
//   {"op":"release-disk"}                         → {"ok":true}  (the disk is closed and mounted again)
//   {"op":"disk-probe","bsd":"disk4"}             → {"ok":true,"raw":{"openRead":"ok",…},"fullDiskAccess":"no",…}
//   {"op":"status"}                               → {"ok":true,"version":4,"fullDiskAccess":"yes","fromBundle":true,
//                                                   "pid":…,"program":"…","busy":0}  (feature "status")
//   {"op":"restart"}                              → {"ok":true}, then the helper exits and launchd starts it again
//                                                   (feature "restart"; macOS applies a new Full Disk Access
//                                                   grant only to a freshly started process)
// A bridge or a USB device lasts until its control connection closes. Only the uid given with
// --allow-uid may connect.
import Foundation
import IdentityCore
import IOKit
import vmnet

/// 2: adds "features" to "version" and the "usb" request.
/// 3: adds the "disk" and "release-disk" requests (feature "disk"). On macOS 26 "usb" cannot take a device
///    away from a macOS driver (it needs Apple's entitlement even for root; see DiskShare.swift), so
///    Tandem only uses it for devices macOS has no driver for.
/// 4: "disk" serves the disk over NBD (qemu-nbd as root) and answers "socket" instead of a device node
///    lent by chown, which macOS 26 refuses even root. Adds "disk-probe" (feature "probe").
let protocolVersion = 4
let maxRequestBytes = 4096
let sendBufferBytes: Int32 = 256 * 1024
let receiveBufferBytes: Int32 = 2 * 1024 * 1024

func logLine(_ message: String) {
    FileHandle.standardError.write(Data("tandem-nethelper: \(message)\n".utf8))
}

func fail(_ message: String) -> Never {
    logLine(message)
    exit(1)
}

func errnoText() -> String { String(cString: strerror(errno)) }

// MARK: Arguments

var controlPath = "/var/run/tandem-net.sock"
var parsedUID: uid_t?
var fakeMode = false
/// The usbredirect program, installed next to the helper by the installer. Nil: USB is not offered.
var usbredirectPath: String?
/// The qemu-nbd program, installed next to the helper by the installer. Nil: USB drives are not offered.
var qemuNBDPath: String?
/// Started by macOS's service manager from inside Tandem.app (see BundleMode.swift).
var bundleMode = false
do {
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--socket":
            guard !args.isEmpty else { fail("--socket needs a path") }
            controlPath = args.removeFirst()
        case "--allow-uid":
            guard !args.isEmpty, let uid = uid_t(args.removeFirst()) else { fail("--allow-uid needs a numeric user id") }
            parsedUID = uid
        case "--fake":
            fakeMode = true
        case "--from-bundle":
            bundleMode = true
        case "--usbredirect":
            guard !args.isEmpty else { fail("--usbredirect needs a path") }
            usbredirectPath = args.removeFirst()
        case "--qemu-nbd":
            guard !args.isEmpty else { fail("--qemu-nbd needs a path") }
            qemuNBDPath = args.removeFirst()
        case "--disk-cooldown":
            // Tests only, and only in fake mode (checked below): how long a dropped disk stays unmountable.
            guard !args.isEmpty, let seconds = TimeInterval(args.removeFirst()), seconds >= 0 else { fail("--disk-cooldown needs seconds") }
            diskCooldown = seconds
        default:
            fail("unknown argument \(arg). Usage: --allow-uid <uid> | --from-bundle [--socket <path>] [--usbredirect <path>] [--qemu-nbd <path>] [--fake]")
        }
    }
    if !fakeMode { diskCooldown = 30 }
}
/// In bundle mode, the team the tools run as root must be signed by (the helper's own).
var requiredToolTeam: String?
/// The team a tool's running image is checked against: only when the helper really runs as root.
var verifiedToolTeam: String? { getuid() == 0 && !fakeMode ? requiredToolTeam : nil }
/// The launchd label this helper was started under (launchd sets XPC_SERVICE_NAME for its jobs).
let launchdLabel = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"].flatMap { $0 == "0" || $0.isEmpty ? nil : $0 }
if bundleMode {
    guard let app = enclosingAppBundle(of: Bundle.main.executablePath ?? CommandLine.arguments[0]) else { fail("--from-bundle: the helper is not inside an app") }
    guard let team = ownTeamIdentifier() else { fail("--from-bundle: the helper is not signed by a developer team") }
    requiredToolTeam = team
    if parsedUID == nil { parsedUID = bundleUser(appBundle: app) }
    let tools = bundledHelperTools(appBundle: app)
    if usbredirectPath == nil, FileManager.default.isExecutableFile(atPath: tools.usbredirect) { usbredirectPath = tools.usbredirect }
    if qemuNBDPath == nil, FileManager.default.isExecutableFile(atPath: tools.qemuNBD) { qemuNBDPath = tools.qemuNBD }
    for (name, path) in [("usbredirect", usbredirectPath), ("qemu-nbd", qemuNBDPath)] {
        guard let path else { logLine("bundle mode: no \(name) in the app"); continue }
        logLine("bundle mode: \(name) \(signedByTeam(path, team: team) ? "signed by team \(team)" : "NOT signed by team \(team); it will not be run")")
    }
}
guard parsedUID != nil else { fail("--allow-uid <uid> is required") }
let allowedUID: uid_t = parsedUID!
guard controlPath.hasSuffix(".sock") else { fail("the socket path must end in .sock") }
/// Datagram sockets are created next to the control socket as `<base>-<n>.dgram`.
let dgramBase = String(controlPath.dropLast(".sock".count))
guard dgramBase.utf8.count + 16 <= 103 else { fail("the socket path is too long") }

// MARK: Socket helpers

func unixAddress(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path.utf8) }
    return addr
}

func withSockaddr<R>(_ addr: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
    var addr = addr
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

/// Binds a unix socket that only the allowed user can open.
func bindPrivate(fd: Int32, path: String) -> String? {
    guard let addr = unixAddress(path) else { return "path too long: \(path)" }
    unlink(path)
    // No access for anyone until ownership and mode are set.
    let oldMask = umask(0o177)
    let rc = withSockaddr(addr) { bind(fd, $0, $1) }
    umask(oldMask)
    guard rc == 0 else { return "cannot bind \(path): \(errnoText())" }
    if chown(path, allowedUID, gid_t.max) != 0 {
        // Only root can give the socket away. Unprivileged runs (tests) own it already.
        if getuid() == 0 { return "cannot chown \(path): \(errnoText())" }
    }
    guard chmod(path, 0o600) == 0 else { return "cannot chmod \(path): \(errnoText())" }
    return nil
}

/// The allowed user's primary group, for doing something with that user's rights.
let allowedGID: gid_t = {
    if let entry = getpwuid(allowedUID) { return entry.pointee.pw_gid }
    return 20 // staff
}()

/// Runs `body` on this thread with the allowed user's rights instead of root's (when the helper is root),
/// so the kernel checks file access as that user would get it. Nil when the rights could not be taken.
func asAllowedUser<R>(_ body: () -> R) -> R? {
    guard getuid() == 0 else { return body() }
    guard pthread_setugid_np(allowedUID, allowedGID) == 0 else { return nil }
    // KAUTH_UID_NONE / KAUTH_GID_NONE: back to the process's own rights.
    defer {
        if pthread_setugid_np(uid_t.max - 100, gid_t.max - 100) != 0 { fail("could not return to the helper's own rights") }
    }
    return body()
}

func setBuffer(_ fd: Int32, _ option: Int32, _ bytes: Int32) {
    var value = bytes
    if setsockopt(fd, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<Int32>.size)) != 0 {
        logLine("could not set socket buffer to \(bytes): \(errnoText())")
    }
}

// MARK: Backends

/// Where frames from the VM go, and where frames for the VM come from.
protocol Backend: AnyObject {
    var mtu: Int { get }
    var maxPacketSize: Int { get }
    /// Called with each frame for the VM. Set before any frame can arrive.
    var deliver: ((UnsafeRawBufferPointer) -> Void)? { get set }
    func write(_ frame: UnsafeMutableRawBufferPointer)
    func stop()
}

/// Test backend: every frame comes straight back.
final class EchoBackend: Backend {
    let mtu = 1500
    let maxPacketSize = 1514
    var deliver: ((UnsafeRawBufferPointer) -> Void)?
    func write(_ frame: UnsafeMutableRawBufferPointer) { deliver?(UnsafeRawBufferPointer(frame)) }
    func stop() {}
}

func describe(_ status: vmnet_return_t) -> String {
    switch status {
    case .VMNET_SUCCESS: return "success"
    case .VMNET_FAILURE: return "general failure (the helper may not be running as root, or the interface cannot be bridged)"
    case .VMNET_MEM_FAILURE: return "out of memory"
    case .VMNET_INVALID_ARGUMENT: return "invalid argument (is the interface name right?)"
    case .VMNET_SETUP_INCOMPLETE: return "interface setup is not complete"
    case .VMNET_INVALID_ACCESS: return "permission denied"
    case .VMNET_PACKET_TOO_BIG: return "packet too big"
    case .VMNET_BUFFER_EXHAUSTED: return "kernel buffers exhausted"
    case .VMNET_TOO_MANY_PACKETS: return "too many packets"
    case .VMNET_SHARING_SERVICE_BUSY: return "the sharing service is busy (Internet Sharing may be on)"
    case .VMNET_NOT_AUTHORIZED: return "not authorised"
    @unknown default: return "vmnet status \(status.rawValue)"
    }
}

final class BackendError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// A vmnet interface bridged onto a physical network interface.
final class VmnetBackend: Backend {
    private let interface: interface_ref
    private let queue: DispatchQueue
    let mtu: Int
    let maxPacketSize: Int
    var deliver: ((UnsafeRawBufferPointer) -> Void)?
    private static let batch = 32
    private let readBuffer: UnsafeMutableRawPointer
    private let iovecs: UnsafeMutablePointer<iovec>
    private let packets: UnsafeMutablePointer<vmpktdesc>

    init(bridging name: String) throws {
        let queue = DispatchQueue(label: "tandem.vmnet.\(name)")
        let desc = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(desc, vmnet_operation_mode_key, UInt64(operating_modes_t.VMNET_BRIDGED_MODE.rawValue))
        xpc_dictionary_set_string(desc, vmnet_shared_interface_name_key, name)
        // The guest keeps its own MAC address.
        xpc_dictionary_set_bool(desc, vmnet_allocate_mac_address_key, false)

        let done = DispatchSemaphore(value: 0)
        var status = vmnet_return_t.VMNET_FAILURE
        var mtu = 1500, maxPacket = 1514
        let ref = vmnet_start_interface(desc, queue) { result, params in
            status = result
            if result == .VMNET_SUCCESS, let params {
                mtu = Int(xpc_dictionary_get_uint64(params, vmnet_mtu_key))
                maxPacket = Int(xpc_dictionary_get_uint64(params, vmnet_max_packet_size_key))
            }
            done.signal()
        }
        guard let ref else { throw BackendError("cannot create the network interface: \(describe(.VMNET_FAILURE))") }
        guard done.wait(timeout: .now() + 15) == .success else { throw BackendError("the network interface did not start in time") }
        guard status == .VMNET_SUCCESS else { throw BackendError("cannot create the network interface: \(describe(status))") }
        guard maxPacket >= 64, maxPacket <= 65536 else { throw BackendError("unexpected packet size \(maxPacket) from vmnet") }

        self.interface = ref
        self.queue = queue
        self.mtu = mtu
        self.maxPacketSize = maxPacket
        readBuffer = UnsafeMutableRawPointer.allocate(byteCount: maxPacket * Self.batch, alignment: 16)
        iovecs = UnsafeMutablePointer<iovec>.allocate(capacity: Self.batch)
        packets = UnsafeMutablePointer<vmpktdesc>.allocate(capacity: Self.batch)

        // The callback runs on `queue`, which is also the only place the read buffers are used.
        let rc = vmnet_interface_set_event_callback(ref, .VMNET_INTERFACE_PACKETS_AVAILABLE, queue) { [weak self] _, _ in
            self?.drain()
        }
        if rc != .VMNET_SUCCESS {
            stop()
            throw BackendError("cannot listen for packets: \(describe(rc))")
        }
    }

    /// Reads everything vmnet has for the guest.
    private func drain() {
        while true {
            for i in 0..<Self.batch {
                iovecs[i] = iovec(iov_base: readBuffer + i * maxPacketSize, iov_len: maxPacketSize)
                packets[i] = vmpktdesc(vm_pkt_size: maxPacketSize, vm_pkt_iov: iovecs + i, vm_pkt_iovcnt: 1, vm_flags: 0)
            }
            var count = Int32(Self.batch)
            guard vmnet_read(interface, packets, &count) == .VMNET_SUCCESS, count > 0 else { return }
            for i in 0..<Int(count) {
                let size = min(packets[i].vm_pkt_size, maxPacketSize)
                deliver?(UnsafeRawBufferPointer(start: readBuffer + i * maxPacketSize, count: size))
            }
            if count < Int32(Self.batch) { return }
        }
    }

    func write(_ frame: UnsafeMutableRawBufferPointer) {
        guard frame.count <= maxPacketSize, let base = frame.baseAddress else { return }
        var io = iovec(iov_base: base, iov_len: frame.count)
        withUnsafeMutablePointer(to: &io) { ioPointer in
            var packet = vmpktdesc(vm_pkt_size: frame.count, vm_pkt_iov: ioPointer, vm_pkt_iovcnt: 1, vm_flags: 0)
            var count: Int32 = 1
            // A full buffer drops the frame, as a real network would.
            _ = vmnet_write(interface, &packet, &count)
        }
    }

    func stop() {
        _ = vmnet_interface_set_event_callback(interface, .VMNET_INTERFACE_PACKETS_AVAILABLE, nil, nil)
        let done = DispatchSemaphore(value: 0)
        let rc = vmnet_stop_interface(interface, queue) { _ in done.signal() }
        if rc == .VMNET_SUCCESS { _ = done.wait(timeout: .now() + 10) }
        // Let a read that was already running finish before the buffers go away.
        queue.sync {}
        readBuffer.deallocate()
        iovecs.deallocate()
        packets.deallocate()
    }
}

@Sendable func sharedInterfaces() -> [String] {
    if fakeMode { return ["fake0"] }
    guard let list = vmnet_copy_shared_interface_list() else { return [] }
    var names: [String] = []
    for i in 0..<xpc_array_get_count(list) {
        if let cString = xpc_array_get_string(list, i) { names.append(String(cString: cString)) }
    }
    return names
}

// MARK: Bridge

let bridgeCounter = NSLock()
nonisolated(unsafe) var nextBridgeNumber = 0

/// One VM's link: a datagram socket on one side, a backend on the other.
final class Bridge {
    let socketPath: String
    private let fd: Int32
    private let peerPath: String
    private let backend: Backend
    private let lock = NSLock()
    private var peerConnected = false
    private var stopping = false
    private let receiverDone = DispatchSemaphore(value: 0)

    init(peerPath: String, makeBackend: () throws -> Backend) throws {
        guard unixAddress(peerPath) != nil, peerPath.hasPrefix("/") else { throw BackendError("the peer socket path is not usable") }
        let number: Int = bridgeCounter.withLock { nextBridgeNumber += 1; return nextBridgeNumber }
        socketPath = "\(dgramBase)-\(number).dgram"
        self.peerPath = peerPath
        fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw BackendError("socket() failed: \(errnoText())") }
        setBuffer(fd, SO_SNDBUF, sendBufferBytes)
        setBuffer(fd, SO_RCVBUF, receiveBufferBytes)
        if let problem = bindPrivate(fd: fd, path: socketPath) {
            close(fd)
            throw BackendError(problem)
        }
        do { backend = try makeBackend() }
        catch {
            close(fd)
            unlink(socketPath)
            throw error
        }
        backend.deliver = { [weak self] frame in self?.sendToPeer(frame) }
        let thread = Thread { [self] in receiveLoop() }
        thread.name = "bridge-receive"
        thread.start()
    }

    var mtu: Int { backend.mtu }
    var maxPacketSize: Int { backend.maxPacketSize }

    /// Connects to the VM's socket the first time there is something to send. The VM may bind its socket
    /// after the bridge is made, so this cannot be done up front. Connecting pins the socket itself, so
    /// replacing the file afterwards changes nothing; it must be a socket owned by the allowed user.
    private func connectPeerIfNeeded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if peerConnected { return true }
        var info = stat()
        guard lstat(peerPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == allowedUID,
              let addr = unixAddress(peerPath) else { return false }
        // The path is the user's: between the check above and connect() it could become a link to a
        // socket of root's (system logging, say), which would then be fed frames from the network. So the
        // kernel checks this connect() with the user's own rights.
        guard asAllowedUser({ withSockaddr(addr, { connect(fd, $0, $1) }) == 0 }) == true else { return false }
        peerConnected = true
        return true
    }

    private func sendToPeer(_ frame: UnsafeRawBufferPointer) {
        guard connectPeerIfNeeded() else { return }
        // Non-blocking: when the VM is not reading, frames are dropped instead of stalling the network.
        _ = send(fd, frame.baseAddress, frame.count, MSG_DONTWAIT)
    }

    private func receiveLoop() {
        let capacity = max(backend.maxPacketSize, 2048)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate(); receiverDone.signal() }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while !lock.withLock({ stopping }) {
            let ready = poll(&descriptor, 1, 250)
            if ready < 0 && errno != EINTR { return }
            if ready <= 0 { continue }
            let n = recv(fd, buffer, capacity, MSG_DONTWAIT)
            if n <= 0 { continue }
            // Frames are only taken once the sender's socket has passed the ownership check.
            guard connectPeerIfNeeded() else { continue }
            backend.write(UnsafeMutableRawBufferPointer(start: buffer, count: n))
        }
    }

    func stop() {
        lock.withLock { stopping = true }
        _ = receiverDone.wait(timeout: .now() + 2)
        backend.stop()
        close(fd)
        unlink(socketPath)
    }
}

// MARK: USB

/// The USB device with these ids plugged in at this place, as libusb names it: "<bus>-<address>".
/// libusb on macOS takes the bus from the top byte of the location and the address from "USB Address".
@Sendable func usbBusAddress(vendor: Int, product: Int, location: UInt32) -> String? {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }
        func number(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
        }
        guard number("idVendor") == vendor, number("idProduct") == product,
              UInt32(truncatingIfNeeded: number("locationID") ?? -1) == location,
              let address = number("USB Address") else { continue }
        return "\(location >> 24)-\(address)"
    }
    return nil
}

/// One redirected USB device: usbredirect (root) ⇄ loopback TCP ⇄ this helper ⇄ unix socket ⇄ QEMU.
/// usbredirect only speaks TCP. It connects out to a port only this helper listens on, so the device is
/// never offered on a network port; the user's side is a unix socket only that user can open.
final class USBRedirect {
    let socketPath: String
    private var process: ToolProcess?
    private let lock = NSLock()
    private var stopping = false
    private var tcpFD: Int32 = -1
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var relayStarted = false
    private let relayDone = DispatchSemaphore(value: 0)

    /// Starts usbredirect for the device and waits until it has opened it and connected to the helper.
    init(device: String, program: String) throws {
        let number: Int = bridgeCounter.withLock { nextBridgeNumber += 1; return nextBridgeNumber }
        socketPath = "\(dgramBase)-usb-\(number).sock"

        // 1. A loopback port for usbredirect to connect to.
        let server = socket(AF_INET, SOCK_STREAM, 0)
        guard server >= 0 else { throw BackendError("socket() failed: \(errnoText())") }
        defer { close(server) }
        var on: Int32 = 1
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(server, 1) == 0 else { throw BackendError("cannot listen on a loopback port: \(errnoText())") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))

        // 2. usbredirect, as root: libusb detaches macOS's driver and the program connects to that port.
        //    Started suspended and checked as loaded when it must be signed by the helper's team.
        let process: ToolProcess
        do { process = try ToolProcess(path: program, arguments: ["--device", device, "--to", "127.0.0.1:\(port)"], team: verifiedToolTeam) }
        catch { throw BackendError("\(error)") }
        self.process = process

        // 3. Its connection, or its reason for not making one.
        var waiting = pollfd(fd: server, events: Int16(POLLIN), revents: 0)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if poll(&waiting, 1, 200) > 0 { break }
            if !process.isRunning { break }
        }
        if waiting.revents & Int16(POLLIN) != 0 { tcpFD = accept(server, nil, nil) }
        guard tcpFD >= 0 else {
            process.end()
            let text = process.errorText()
            throw BackendError(text.isEmpty ? "usbredirect could not open the device" : "usbredirect: \(text)")
        }
        setsockopt(tcpFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        // 4. The user's end.
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { stop(); throw BackendError("socket() failed: \(errnoText())") }
        if let problem = bindPrivate(fd: listenFD, path: socketPath) { stop(); throw BackendError(problem) }
        guard listen(listenFD, 1) == 0 else { stop(); throw BackendError("listen() failed: \(errnoText())") }

        relayStarted = true
        let thread = Thread { [self] in relay() }
        thread.name = "usb-relay"
        thread.start()
    }

    /// Waits for QEMU, then copies bytes both ways until either side closes.
    private func relay() {
        defer { relayDone.signal() }
        var waiting = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
        while !lock.withLock({ stopping }) {
            let ready = poll(&waiting, 1, 250)
            if ready < 0 && errno != EINTR { return }
            if ready <= 0 { continue }
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { continue }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == allowedUID else { close(fd); continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            lock.withLock { clientFD = fd }
            break
        }
        let client = lock.withLock { clientFD }
        guard client >= 0 else { return }
        // When either side ends, the other must see it end too (QEMU then reports the device gone,
        // and usbredirect exits, which hands the device back to macOS). The descriptors close in stop().
        defer { shutdown(client, SHUT_RDWR); shutdown(tcpFD, SHUT_RDWR) }
        var fds = [pollfd(fd: tcpFD, events: Int16(POLLIN), revents: 0), pollfd(fd: client, events: Int16(POLLIN), revents: 0)]
        let size = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        func pump(_ from: Int32, _ to: Int32) -> Bool {
            let n = read(from, buffer, size)
            if n <= 0 { return false }
            var offset = 0
            while offset < n {
                let w = write(to, buffer + offset, n - offset)
                if w <= 0 { return false }
                offset += w
            }
            return true
        }
        while !lock.withLock({ stopping }) {
            let ready = poll(&fds, 2, 250)
            if ready < 0 && errno != EINTR { return }
            if ready <= 0 { continue }
            if fds[0].revents != 0, !pump(tcpFD, client) { return }
            if fds[1].revents != 0, !pump(client, tcpFD) { return }
        }
    }

    /// Ends the redirection: usbredirect exits and macOS takes the device back.
    func stop() {
        let already: Bool = lock.withLock { let was = stopping; stopping = true; return was }
        if already { return }
        if relayStarted { _ = relayDone.wait(timeout: .now() + 2) }
        for fd in [clientFD, tcpFD, listenFD] where fd >= 0 { close(fd) }
        // Give libusb time to hand the device back to macOS before forcing it.
        process?.end(grace: 5)
        unlink(socketPath)
    }
}

// MARK: Control connections

@Sendable func reply(_ fd: Int32, _ object: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    data.append(0x0A)
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if n <= 0 { return }
            offset += n
        }
    }
}

/// Connections that hold a bridge, USB device or drive right now ("restart" refuses while any do).
let holdingConnections = NSLock()
nonisolated(unsafe) var holdingCount = 0
@Sendable func lentResourceCount() -> Int { holdingConnections.withLock { holdingCount } }

@Sendable func serve(_ fd: Int32) {
    var bridge: Bridge?
    var usb: USBRedirect?
    var disk: DiskShare?
    var counted = false
    func syncHolding() {
        let holds = bridge != nil || usb != nil || disk != nil
        guard holds != counted else { return }
        holdingConnections.withLock { holdingCount += holds ? 1 : -1 }
        counted = holds
    }
    defer {
        if counted { holdingConnections.withLock { holdingCount -= 1 } }
        if let disk {
            // Closed without "release-disk": the VM may not have let go, so the disk is not mounted again.
            logLine("disk \(disk.bsd) connection closed; stopping its server")
            disk.release(remount: false)
            logLine("disk \(disk.bsd) closed without release; not mounted again")
        }
        bridge?.stop()
        if let bridge { logLine("bridge \(bridge.socketPath) closed") }
        usb?.stop()
        if let usb { logLine("usb \(usb.socketPath) closed") }
        close(fd)
    }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

    var uid: uid_t = 0, gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == allowedUID else {
        reply(fd, ["ok": false, "error": "this user may not use the Tandem network helper"])
        return
    }

    var pending = Data()
    var chunk = [UInt8](repeating: 0, count: 1024)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { return }
        pending.append(contentsOf: chunk[0..<n])
        while let newline = pending.firstIndex(of: 0x0A) {
            defer { syncHolding() }
            let line = pending.subdata(in: pending.startIndex..<newline)
            pending.removeSubrange(pending.startIndex...newline)
            guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let op = request["op"] as? String else {
                reply(fd, ["ok": false, "error": "bad request"])
                continue
            }
            switch op {
            case "version":
                var features = ["bridge"]
                if usbredirectPath != nil { features.append("usb") }
                if qemuNBDPath != nil { features.append("disk") }
                features.append("probe")
                features.append("restart")
                features.append("status")
                reply(fd, ["ok": true, "version": protocolVersion, "features": features])
            case "status":
                reply(fd, ["ok": true, "version": protocolVersion, "fullDiskAccess": fullDiskAccessState(),
                           "fromBundle": bundleMode, "pid": Int(getpid()),
                           "program": Bundle.main.executablePath ?? CommandLine.arguments[0], "busy": lentResourceCount(),
                           "label": launchdLabel ?? ""])
            case "restart":
                // Only with nothing lent out on any connection, so no VM loses its drive or USB device.
                guard lentResourceCount() == 0 else {
                    reply(fd, ["ok": false, "error": "the helper is serving a USB drive, USB device or network bridge; stop those VMs first"]); continue
                }
                reply(fd, ["ok": true])
                logLine("restarting on request")
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { exit(0) }
            case "disk-probe":
                guard let bsd = request["bsd"] as? String else { reply(fd, ["ok": false, "error": "disk-probe needs \"bsd\""]); continue }
                reply(fd, diskProbe(bsd: bsd))
            case "disk":
                guard usb == nil, bridge == nil, disk == nil else { reply(fd, ["ok": false, "error": "this connection is already in use"]); continue }
                guard let bsd = request["bsd"] as? String else { reply(fd, ["ok": false, "error": "disk needs \"bsd\""]); continue }
                guard let program = qemuNBDPath, FileManager.default.isExecutableFile(atPath: program) else {
                    reply(fd, ["ok": false, "error": "this helper was installed without USB drive support; install it again"]); continue
                }
                guard fakeMode || getuid() != 0 || mayRunAsRoot(program, requiredTeam: requiredToolTeam) else {
                    logLine("refused to run \(program): not signed by the helper's team, or writable by others")
                    reply(fd, ["ok": false, "error": "the helper's copy of qemu-nbd is not trusted (changed after installation?); install Tandem again"]); continue
                }
                do {
                    let made = try DiskShare(bsd: bsd, allowDiskImages: fakeMode, qemuNBD: program)
                    disk = made
                    reply(fd, ["ok": true, "socket": made.socketPath, "readOnly": made.readOnly, "size": made.size])
                    logLine("disk \(bsd) served on \(made.socketPath)\(made.readOnly ? " read-only" : "")")
                } catch let error as BackendError {
                    logLine("disk \(bsd) refused: \(error.message)")
                    reply(fd, ["ok": false, "error": error.message])
                } catch {
                    logLine("disk \(bsd) refused: \(error)")
                    reply(fd, ["ok": false, "error": "\(error)"])
                }
            case "release-disk":
                guard let held = disk else { reply(fd, ["ok": false, "error": "no disk is held on this connection"]); continue }
                let problem = held.release(remount: true)
                disk = nil
                if let problem {
                    logLine("disk \(held.bsd) released; \(problem)")
                    reply(fd, ["ok": true, "mounted": false, "warning": problem])
                } else {
                    logLine("disk \(held.bsd) released and mounted again")
                    reply(fd, ["ok": true, "mounted": true])
                }
            case "usb":
                guard usb == nil, bridge == nil else { reply(fd, ["ok": false, "error": "this connection is already in use"]); continue }
                guard let program = usbredirectPath, FileManager.default.isExecutableFile(atPath: program) else {
                    reply(fd, ["ok": false, "error": "this helper was installed without USB support; install it again"]); continue
                }
                guard let vendor = request["vendor"] as? Int, let product = request["product"] as? Int,
                      let location = (request["location"] as? NSNumber)?.uint32Value else {
                    reply(fd, ["ok": false, "error": "usb needs \"vendor\", \"product\" and \"location\""]); continue
                }
                let device: String
                if fakeMode { device = String(format: "%04x:%04x", vendor, product) }
                else if let found = usbBusAddress(vendor: vendor, product: product, location: location) { device = found }
                else { reply(fd, ["ok": false, "error": "the device is not plugged in"]); continue }
                if !fakeMode, let driver = macOSDriverHolding(vendor: vendor, product: product, location: location) {
                    reply(fd, ["ok": false, "error": "macOS is using this device with its own driver (\(driver)); taking it away needs an Apple entitlement that Tandem does not have, and trying would leave the device unusable until it is plugged in again"])
                    continue
                }
                guard fakeMode || getuid() != 0 || mayRunAsRoot(program, requiredTeam: requiredToolTeam) else {
                    logLine("refused to run \(program): not signed by the helper's team, or writable by others")
                    reply(fd, ["ok": false, "error": "the helper's copy of usbredirect is not trusted (changed after installation?); install Tandem again"]); continue
                }
                do {
                    let made = try USBRedirect(device: device, program: program)
                    usb = made
                    logLine("usb \(device) on \(made.socketPath)")
                    reply(fd, ["ok": true, "socket": made.socketPath])
                } catch let error as BackendError {
                    reply(fd, ["ok": false, "error": error.message])
                } catch {
                    reply(fd, ["ok": false, "error": "\(error)"])
                }
            case "interfaces":
                reply(fd, ["ok": true, "interfaces": sharedInterfaces()])
            case "bridge":
                guard bridge == nil else { reply(fd, ["ok": false, "error": "this connection already has a bridge"]); continue }
                guard let name = request["interface"] as? String, let peer = request["peer"] as? String else {
                    reply(fd, ["ok": false, "error": "bridge needs \"interface\" and \"peer\""]); continue
                }
                guard sharedInterfaces().contains(name) else {
                    reply(fd, ["ok": false, "error": "\(name) is not a network interface that can be bridged"]); continue
                }
                do {
                    let made = try Bridge(peerPath: peer) {
                        if fakeMode { return EchoBackend() }
                        return try VmnetBackend(bridging: name)
                    }
                    bridge = made
                    logLine("bridge \(made.socketPath) on \(name) for \(peer)")
                    reply(fd, ["ok": true, "socket": made.socketPath, "mtu": made.mtu, "maxPacketSize": made.maxPacketSize])
                } catch let error as BackendError {
                    reply(fd, ["ok": false, "error": error.message])
                } catch {
                    reply(fd, ["ok": false, "error": "\(error)"])
                }
            default:
                reply(fd, ["ok": false, "error": "unknown op \(op)"])
            }
        }
        if pending.count > maxRequestBytes { return }
    }
}

// MARK: Main

signal(SIGPIPE, SIG_IGN)

// Datagram sockets left behind by an earlier run.
do {
    let directory = (dgramBase as NSString).deletingLastPathComponent
    let prefix = (dgramBase as NSString).lastPathComponent + "-"
    for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where name.hasPrefix(prefix) && (name.hasSuffix(".dgram") || name.hasSuffix(".sock")) {
        unlink(directory + "/" + name)
    }
}

let listener = socket(AF_UNIX, SOCK_STREAM, 0)
guard listener >= 0 else { fail("socket() failed: \(errnoText())") }
if let problem = bindPrivate(fd: listener, path: controlPath) { fail(problem) }
guard listen(listener, 8) == 0 else { fail("listen() failed: \(errnoText())") }

// launchd stops the daemon with SIGTERM. Exiting closes every vmnet interface; the socket file is removed here.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let signalQueue = DispatchQueue(label: "tandem.signals")
let signalSources: [DispatchSourceSignal] = [SIGTERM, SIGINT].map { number in
    let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
    source.setEventHandler {
        unlink(controlPath)
        exit(0)
    }
    source.resume()
    return source
}

endOrphanedChildren()
logLine("listening on \(controlPath) for uid \(allowedUID)\(fakeMode ? " (fake mode)" : "")\(bundleMode ? " (from the app, team \(requiredToolTeam ?? "?"))" : "")")
while true {
    let client = accept(listener, nil, nil)
    if client < 0 {
        if errno == EINTR { continue }
        fail("accept() failed: \(errnoText())")
    }
    let thread = Thread { serve(client) }
    thread.name = "control"
    thread.start()
}

/// Disk servers and USB redirectors left by an earlier helper process (one that crashed or was replaced
/// by a reinstall) are orphans: launchd became their parent. Nothing can use them any more, and a
/// leftover disk server keeps the disk from the Mac, so they are ended when the helper starts.
func endOrphanedChildren() {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return }
    var pids = [pid_t](repeating: 0, count: Int(count) + 16)
    let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    for pid in pids.prefix(Int(max(found, 0))) where pid > 1 {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
        let executable = String(cString: path)
        // Installed by scripts/install-net-helper.sh.
        let installed = executable.hasPrefix("/Library/PrivilegedHelperTools/\(TandemIdentity.prefix).")
            && (executable.hasSuffix("/qemu-nbd") || executable.hasSuffix("/usbredirect"))
        // From the app: the very tools this helper would run (an earlier helper ran them from there too).
        let fromApp = bundleMode && [usbredirectPath, qemuNBDPath].contains { $0 == executable }
        guard installed || fromApp else { continue }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        // Only root's: the user may run the app's qemu-nbd for themselves, and those are not ours to end.
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid == 1, info.pbi_uid == 0 else { continue }
        kill(pid, SIGTERM)
        logLine("ended \(URL(fileURLWithPath: executable).lastPathComponent) \(pid) left by an earlier helper")
    }
}
