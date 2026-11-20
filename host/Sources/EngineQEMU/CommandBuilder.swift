import Foundation
import VMCore
import GuestLink

public enum QEMUDisplayMode: String, Sendable {
    /// QEMU opens its own window.
    case cocoa
    /// QEMU serves the screen on a private unix socket and the app draws it in its own window (`RFBClient`).
    case embedded
    /// No display. Used by tests and headless runs.
    case none
}

/// Paths of the per-run control sockets. Kept short because unix socket paths are limited to 103 bytes.
public struct QEMURunPaths: Sendable, Equatable {
    public var directory: URL
    public var qmp: String { directory.appendingPathComponent("qmp.sock").path }
    public var guestLink: String { directory.appendingPathComponent("gl.sock").path }
    public var tpm: String { directory.appendingPathComponent("tpm.sock").path }
    public var display: String { directory.appendingPathComponent("vnc.sock").path }
    /// The VM's end of a bridged network: a datagram socket QEMU binds, one Ethernet frame per datagram.
    public var network: String { directory.appendingPathComponent("net.sock").path }

    /// Stand-ins swtpm is given for the VM's TPM folder and log when their paths hold a comma: swtpm's
    /// option parser has no way to write one (QEMU's doubles it, swtpm's does not; tried with swtpm 0.10).
    public var tpmStateLink: String { directory.appendingPathComponent("tpm-state").path }
    /// A link to the logs folder, not to the log: swtpm opens its log without following links.
    public var tpmLogLink: String { directory.appendingPathComponent("logs").path }

    public init(directory: URL) { self.directory = directory }

    /// Named for the VM's full identifier (RunFolder), so two VMs never share a folder.
    public static func forVM(_ id: UUID) -> QEMURunPaths {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(RunFolder.name(for: id, longestSocketName: "qmp.sock"), isDirectory: true)
        return QEMURunPaths(directory: dir)
    }
}

/// Writing values into QEMU's comma-separated option strings (`-drive file=…,format=…`). A comma inside a
/// value is written twice, or QEMU would read the rest as further options: a disk in
/// "/Volumes/Work, Archive" would not start. (Not for `-serial file:` and `-L`, which take the path as it is.)
public enum QEMUOption {
    public static func value(_ text: String) -> String { text.replacingOccurrences(of: ",", with: ",,") }
}

/// Builds the `qemu-system-aarch64` argument list from a `VMConfig`. Pure: no side effects.
public enum QEMUCommandBuilder {
    public static func needsTPM(_ config: VMConfig) -> Bool { config.tpm }

    /// `guestToolsISO` is the Linux guest tools disc; it is attached to Linux guests as a CD drive.
    /// `hostServicePort` is where the Mac serves this VM's shared folders; a bridged VM gets a private path to it.
    /// `incoming` is a QEMU migration source to resume from (see `QEMUEngine.suspend`).
    /// `bridgeSocket` is the network helper's end of a bridge, required when the VM's network is bridged.
    /// Whether a VM runs with 3D acceleration: Linux guests that asked for it (experimental).
    public static func uses3D(_ c: VMConfig) -> Bool {
        (c.guestOS == .linux || c.guestOS == .windows11arm) && c.display.accelerated3D == true
    }

    /// Windows 3D (experimental): the open, Microsoft-signed ARM64 display driver from UTM's guest tools
    /// ("viogpu3d", Direct3D 11 through Neptune and DXMT) on QEMU's virtio-ramfb-gl device.
    public static func usesWindows3D(_ c: VMConfig) -> Bool { uses3D(c) && c.guestOS == .windows11arm }

    /// The host-memory window for Windows 3D: blob resources are mapped into it. Half of the guest's
    /// memory, at most 8 GiB, at least 1 GiB.
    public static func windows3DHostMemoryMiB(_ c: VMConfig) -> Int { min(8192, max(1024, c.memoryMiB / 2)) }

    /// The display backend of a 3D VM: GL rendering with no window of its own, read back for VNC.
    static func display3D(es: Bool) -> String { es ? "egl-headless,gl=es" : "egl-headless,gl=core" }

    public static func arguments(bundle: VMBundle, toolchain: QEMUToolchain, paths: QEMURunPaths,
                                 display: QEMUDisplayMode, guestToolsISO: URL? = nil,
                                 bridgeSocket: String? = nil, incoming: String? = nil,
                                 hostServicePort: Int? = nil, serviceBackends: [Int: Int] = [:]) throws -> [String] {
        // The sharing policy cuts the network down to what the VM's profile allows before anything is built.
        let policy = SharingPolicy(bundle.config)
        let c = policy.enforced(bundle.config)
        guard c.engine == .qemu else { throw VMError("“\(c.name)” is not a QEMU virtual machine.") }
        guard c.guestOS != .macos else { throw VMError("macOS guests run on the VZ engine.") }
        let windows = c.guestOS == .windows11arm
        var a: [String] = []

        let v = QEMUOption.value
        a += ["-name", v(c.name), "-uuid", (c.hardwareUUID ?? c.id).uuidString.lowercased(), "-nodefaults"]
        if usesWindows3D(c) {
            // Blob resources are mapped into the guest at 4 KiB granularity, which the Windows driver needs.
            a += ["-machine", "virt,highmem=on", "-accel", "hvf,ipa-granule-size=0x1000", "-cpu", "host"]
        } else {
            a += ["-machine", "virt,accel=hvf,highmem=on", "-cpu", "host"]
        }
        a += ["-smp", "\(c.cpuCount)", "-m", "\(c.memoryMiB)"]
        if windows { a += ["-rtc", "base=localtime"] }

        // UEFI firmware: shared read-only code, per-VM variable store.
        if let data = toolchain.dataDirectory { a += ["-L", data.path] }
        a += ["-drive", "if=pflash,format=raw,readonly=on,file=\(v(toolchain.firmwareCode.path))"]
        a += ["-drive", "if=pflash,format=raw,file=\(v(bundle.efiVarsURL.path))"]

        // Input over xHCI: Windows ARM has inbox drivers for it.
        a += ["-device", "qemu-xhci,id=usb", "-device", "usb-kbd,bus=usb.0", "-device", "usb-tablet,bus=usb.0"]

        let boot = BootPlan(c)
        if c.bootOrDefault.menu {
            // The firmware waits this long for Escape, which opens its boot menu.
            a += ["-boot", "menu=on,splash-time=5000"]
        }
        for (i, disk) in c.disks.enumerated() {
            let id = "disk\(i)"
            a += ["-drive", "if=none,id=\(id),format=\(disk.format.rawValue),file=\(v(bundle.diskURL(disk).path)),discard=unmap,detect-zeroes=unmap"]
            switch disk.bus {
            case .nvme: a += ["-device", "nvme,drive=\(id),serial=\(id)\(boot.disk(i))"]
            case .virtio: a += ["-device", "virtio-blk-pci,drive=\(id)\(boot.disk(i))"]
            }
        }
        for (i, media) in c.removableMedia.enumerated() {
            let id = "media\(i)"
            let path = v(bundle.mediaURL(media).path)
            switch media.kind {
            case .installerISO:
                a += ["-drive", "if=none,id=\(id),media=cdrom,format=raw,readonly=on,file=\(path)"]
                a += ["-device", "usb-storage,bus=usb.0,drive=\(id),removable=on\(boot.media(i))"]
            case .unattendDisk, .driverDisc:
                // Must be a CD drive: Windows shows an ISO image on a plain USB disk as an unformatted volume.
                a += ["-drive", "if=none,id=\(id),media=cdrom,format=raw,readonly=on,file=\(path)"]
                a += ["-device", "usb-storage,bus=usb.0,drive=\(id),removable=on"]
            case .seedISO:
                a += ["-drive", "if=none,id=\(id),format=raw,readonly=on,file=\(path)"]
                a += ["-device", "virtio-blk-pci,drive=\(id)"]
            }
        }

        if c.guestOS == .linux {
            if let guestToolsISO {
                a += ["-drive", "if=none,id=tools,media=cdrom,format=raw,readonly=on,file=\(v(guestToolsISO.path))"]
                a += ["-device", "usb-storage,bus=usb.0,drive=tools,removable=on"]
            }
            // Shared Mac folders: one 9p device each. The guest agent mounts tag tandemN under /media/mac.
            // security_model=none: files keep the Mac user's ownership and nothing is written as extra attributes.
            for (i, folder) in c.sharedFolders.enumerated() {
                let path = v(folder.hostPath)
                a += ["-fsdev", "local,id=share\(i),path=\(path),security_model=none\(folder.readOnly ? ",readonly=on" : "")"]
                // Each folder's device sits on a hot-plug port of its own, so that it can be pulled out of a
                // running guest when the folder stops being shared (`QEMUEngine.detachSharedFolders`).
                a += ["-device", "pcie-root-port,id=shareport\(i),bus=pcie.0,chassis=\(i + 1)"]
                a += ["-device", "virtio-9p-pci,id=sharedev\(i),bus=shareport\(i),fsdev=share\(i),mount_tag=tandem\(i)"]
            }
        }

        switch c.network.mode {
        case .nat:
            // User-mode NAT: no entitlement or root needed, but no inbound connections except forwards.
            var netdev = "user,id=net0"
            if !policy.network.outbound {
                // No network access: restrict=on drops everything the guest sends, to the Mac and beyond.
                // The one thing left open is the path to the Mac folders shared with it.
                netdev += ",restrict=on"
                if let port = hostServicePort, port > 0 { netdev += ",guestfwd=tcp:10.0.2.2:\(port)-cmd:/usr/bin/nc 127.0.0.1 \(port)" }
            }
            for f in c.network.portForwards { netdev += ",hostfwd=tcp:127.0.0.1:\(f.hostPort)-:\(f.guestPort)" }
            // Published services: user-mode networking has no way in from the Mac, so each guest port gets a
            // private loopback port here, and the service relay (Sharing/ServicePublisher) listens in front of it.
            // Only where the sharing profile allows connections into the VM, whatever the caller passed.
            for (guestPort, backend) in serviceBackends.sorted(by: { $0.key < $1.key }) where policy.allowsInboundServices {
                netdev += ",hostfwd=tcp:127.0.0.1:\(backend)-:\(guestPort)"
            }
            a += ["-netdev", netdev]
        case .bridged:
            guard let bridgeSocket else {
                throw VMError("Bridged networking needs the Tandem network helper.", detail: "Install it once with: sudo scripts/install-net-helper.sh")
            }
            a += ["-netdev", "dgram,id=net0,local.type=unix,local.path=\(v(paths.network)),remote.type=unix,remote.path=\(v(bridgeSocket))"]
        }
        a += ["-device", "virtio-net-pci,netdev=net0,mac=\(c.network.mac)\(boot.network)"]
        if c.network.mode == .bridged, let port = hostServicePort, port > 0 {
            // A bridged guest cannot reach the Mac's loopback address, where the shared folders are served.
            // A second, isolated adapter gives it that one destination and nothing else: restrict=on blocks
            // everything except this forward, which hands each connection to the Mac's server.
            a += ["-netdev", "user,id=net1,restrict=on,guestfwd=tcp:10.0.2.2:\(port)-cmd:/usr/bin/nc 127.0.0.1 \(port)"]
            a += ["-device", "virtio-net-pci,netdev=net1,mac=\(Self.secondMAC(c.network.mac))"]
        }

        // ramfb gives Windows a firmware framebuffer before any GPU driver exists.
        // Windows without the virtio display driver cannot draw on virtio-gpu after boot, so it keeps ramfb.
        let virtioDisplay = !windows || c.display.virtioGPU == true
        let gl = uses3D(c) && display != .none
        if uses3D(c) {
            // OpenGL through virglrenderer. Tandem's 3D QEMU build carries egl-headless for macOS
            // (patches/qemu-10.0.12-utm-egl-headless-darwin.patch): the guest renders on the Mac's GPU and each
            // finished frame is read back into the console, so the same VNC socket as for 2D VMs shows it in
            // Tandem's window, with input, screenshots and resizing.
            if usesWindows3D(c) {
                // virtio-gpu with GL plus a ramfb for the firmware and Windows Setup; neptune carries Direct3D
                // to virglrenderer, which hands it to DXMT (Direct3D 11 on Metal). blob resources live in hostmem.
                a += ["-device", "virtio-ramfb-gl,xres=\(c.display.width),yres=\(c.display.height),neptune=on,blob=on,hostmem=\(windows3DHostMemoryMiB(c))M"]
            } else {
                a += ["-device", "virtio-gpu-gl-pci,xres=\(c.display.width),yres=\(c.display.height)"]
            }
        } else {
            a += ["-device", virtioDisplay ? "virtio-gpu-pci,xres=\(c.display.width),yres=\(c.display.height)" : "ramfb"]
        }
        if gl {
            // gl=core: virglrenderer on Apple's desktop OpenGL gives the guest OpenGL 4.1 (measured: 4.1 core,
            // GLES 3.0). gl=es (ANGLE on Metal) gives only OpenGL 2.1 and GLES 3.0. TANDEM_3D_GL=es selects ANGLE.
            // TANDEM_3D_DISPLAY (tests only) replaces the display, e.g. "cocoa,gl=core" for QEMU's own window.
            if let custom = ProcessInfo.processInfo.environment["TANDEM_3D_DISPLAY"], !custom.isEmpty {
                a += ["-display", custom]
            } else {
                a += ["-display", Self.display3D(es: ProcessInfo.processInfo.environment["TANDEM_3D_GL"] == "es")]
            }
            a += ["-vnc", "unix:\(v(paths.display))"]
            a += soundArguments(c.soundOrDefault)
        } else {
        switch display {
        case .cocoa:
            a += ["-display", "cocoa"]
            a += soundArguments(c.soundOrDefault)
        case .embedded:
            // The socket lives in the per-run directory, which is mode 0700, so only this user can connect.
            a += ["-display", "none", "-vnc", "unix:\(v(paths.display))"]
            a += soundArguments(c.soundOrDefault)
        case .none:
            a += ["-display", "none"]
        }
        }

        if needsTPM(c) {
            a += ["-chardev", "socket,id=chrtpm,path=\(v(paths.tpm))"]
            // The 3D build is UTM's QEMU 10.0, whose ARM TPM device has no ppi property (QEMU 11's does).
            a += ["-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
                  "-device", uses3D(c) ? "tpm-tis-device,tpmdev=tpm0" : "tpm-tis-device,tpmdev=tpm0,ppi=off"]
        }

        // Guest channel: virtio-serial, because vsock is not available to QEMU on macOS.
        a += ["-device", "virtio-serial-pci"]
        a += ["-chardev", "socket,id=gl,path=\(v(paths.guestLink)),server=on,wait=off"]
        a += ["-device", "virtserialport,chardev=gl,name=\(GuestLinkConstants.serialPortName)"]

        a += ["-qmp", "unix:\(v(paths.qmp)),server=on,wait=off"]
        // `file:` takes the rest of the value as the path, commas included (tried with Tandem's QEMU).
        a += ["-serial", "file:\(bundle.logsDirectory.appendingPathComponent("console.log").path)"]
        // Resume a suspended VM: QEMU loads the saved state from this source, then runs.
        if let incoming { a += ["-incoming", incoming] }
        return a
    }

    /// An Intel HD Audio card on the Mac's sound devices. Without the microphone the card has an output
    /// only, so QEMU never opens the Mac's input device (which macOS guards with a permission prompt).
    static func soundArguments(_ sound: SoundConfig) -> [String] {
        guard sound.output || sound.microphone else { return [] }
        let codec = sound.microphone ? "hda-duplex" : "hda-output"
        return ["-audiodev", "coreaudio,id=audio0", "-device", "ich9-intel-hda", "-device", "\(codec),audiodev=audio0"]
    }

    /// The `bootindex` each device gets: the firmware tries devices in rising order and skips those without one.
    struct BootPlan {
        private var disks: [Int: Int] = [:]
        private var medias: [Int: Int] = [:]
        private var net: Int?

        init(_ c: VMConfig) {
            var next = 0
            for device in c.bootOrDefault.order {
                switch device {
                case .hardDisk:
                    for i in c.disks.indices { disks[i] = next; next += 1 }
                case .cd:
                    for (i, media) in c.removableMedia.enumerated() where media.kind == .installerISO { medias[i] = next; next += 1 }
                case .network:
                    net = next; next += 1
                }
            }
        }

        private func option(_ index: Int?) -> String { index.map { ",bootindex=\($0)" } ?? "" }
        func disk(_ i: Int) -> String { option(disks[i]) }
        func media(_ i: Int) -> String { option(medias[i]) }
        var network: String { option(net) }
    }

    /// A second address for the same VM: the first one with its last byte changed.
    static func secondMAC(_ mac: String) -> String {
        var parts = mac.split(separator: ":").map(String.init)
        guard parts.count == 6, let last = UInt8(parts[5], radix: 16) else { return "02:54:4e:44:4d:01" }
        parts[5] = String(format: "%02x", last ^ 0x80)
        return parts.joined(separator: ":")
    }

    public static func swtpmArguments(bundle: VMBundle, paths: QEMURunPaths) -> [String] {
        let links = swtpmLinks(bundle: bundle, paths: paths).map(\.link)
        let state = links.contains(paths.tpmStateLink) ? paths.tpmStateLink : bundle.tpmDirectory.path
        let log = links.contains(paths.tpmLogLink) ? paths.tpmLogLink + "/swtpm.log" : swtpmLogPath(bundle)
        return ["socket", "--tpm2",
                "--tpmstate", "dir=\(state)",
                "--ctrl", "type=unixio,path=\(paths.tpm)",
                "--log", "file=\(log),level=1",
                "--terminate"]
    }

    static func swtpmLogPath(_ bundle: VMBundle) -> String { bundle.logsDirectory.appendingPathComponent("swtpm.log").path }

    /// The links the engine makes in the run folder before starting swtpm: one for each of the TPM folder
    /// and the log whose path holds a comma (swtpm cannot be given such a path).
    public static func swtpmLinks(bundle: VMBundle, paths: QEMURunPaths) -> [(link: String, target: String)] {
        var links: [(link: String, target: String)] = []
        if bundle.tpmDirectory.path.contains(",") { links.append((paths.tpmStateLink, bundle.tpmDirectory.path)) }
        if swtpmLogPath(bundle).contains(",") { links.append((paths.tpmLogLink, bundle.logsDirectory.path)) }
        return links
    }
}
