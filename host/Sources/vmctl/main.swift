import AppKit
import Foundation
import NetHelperClient
import VMCore
import EngineVZ
import EngineQEMU
import GuestLink
import Provisioning
import Migration
import Sharing
import CoreGraphics
import ImageIO

// vmctl: command-line client of VMCore. Planned for Phase 7; pulled forward as the test harness.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("vmctl: " + message + "\n").utf8))
    exit(1)
}

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []
    init(_ raw: [String], flagNames: Set<String> = ["headless", "force", "json", "tpm", "copy", "embedded", "clipboard-test", "any-host", "read-only", "no-agent-update", "restart-test", "windows-test", "lan", "programs-test", "temporary", "auto-login", "no-auto-login", "no-template", "all", "keep-identity", "include-snapshots", "keep-suspended", "no-identity-reset"]) {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if flagNames.contains(name) { flags.insert(name) }
                else if i + 1 < raw.count { options[name] = raw[i + 1]; i += 1 }
                else { fail("option --\(name) needs a value") }
            } else { positional.append(a) }
            i += 1
        }
    }
    func int(_ name: String) -> Int? {
        guard let v = options[name] else { return nil }
        guard let n = Int(v) else { fail("--\(name) must be a number") }
        return n
    }
}

let usage = """
usage: vmctl <command> [options]

  list [--json]                         List VMs
  show <vm>                             Print a VM's config
  publish <vm> <name> --guest-port N [--host-port N] [--lan]
                                        Give a guest service a fixed port and name on this Mac
  unpublish <vm> <name>                 Stop publishing it
  services [<vm>] [--json]              Published services and whether they are being served
  check [--os linux|windows11arm|macos] [--engine vz|qemu] [--arch arm64|x86_64] [--iso PATH]
        [--memory MiB] [--cpus N] [--disk GiB] [--json]
                                        What this Mac supports for such a VM (exit 2 if it cannot be made)
  create <name> --os linux|windows11arm|macos
         [--engine vz|qemu] [--cpus N] [--memory MiB] [--disk GiB]
         [--iso PATH] [--seed PATH] [--import-disk PATH] [--tpm]
  create <name> --download <system>[:option] [--user NAME --password TEXT] [--cpus N] [--memory MiB] [--disk GiB]
                                        [--desktop mate|xfce|gnome] (Ubuntu Desktop choices)
                                        Download a system and make a VM from it (see: vmctl download list)
  download list [system] [--json]       Systems Tandem can download, with the option IDs to pass to --download
  download get <system> [--option ID]   Download into the library's cache without making a VM
  templates list [--json]               Prepared copies of downloaded Linux systems (made on first use)
  templates delete <option ID> | --all  Delete templates; the next VM of that system sets itself up again
  inspect-parallels <path.pvm|.macvm>   Show what importing a Parallels VM would do (reads only)
  import-parallels <path.pvm|.macvm> [--name N] [--copy] [--windows-iso PATH] [--virtio-iso PATH]
                                        Import a Parallels VM. The original is never written. Default: no disk copy
                                        (overlay on the original for .pvm, APFS clone for .macvm); --copy converts
                                        the whole disk so the VM no longer depends on the original.
                                        Windows VMs need --windows-iso (a Windows 11 ARM64 installer) to be made
                                        bootable; --virtio-iso adds network and display drivers
  repair-windows-import <vm> --windows-iso PATH [--virtio-iso PATH]
                                        Run the Windows boot repair on an already imported VM
  start <vm> [--headless|--embedded]    Run in the foreground until the guest stops (Ctrl-C = shut down).
                                        --embedded serves the screen for `screenshot` instead of opening a window
  screenshot <vm> <out.png>             Save the screen of a QEMU VM started with --embedded
  input <vm> <step>...                  Send input to such a VM. Steps: key:<mac keycode>[+<keycode>...] (press together),
                                        type:<text> (\\n = Return)
                                        move:<x>,<y>  click:<x>,<y>  rclick:<x>,<y>  wait:<seconds>
  sharing <vm> [--preset restricted|default] [--clipboard off|to-guest|to-mac|both] [--usb on|off]
          [--outbound on|off] [--inbound on|off] [--bridged on|off] [--temporary] [--json]
                                        Show, and with options change, what the VM shares with the Mac. Changes reach
                                        a running VM within a second. --temporary (clipboard, USB) lasts until shutdown
  share <vm> <folder> [--name N] [--read-only] [--temporary]
                                        Share a Mac folder with the VM; --temporary until it shuts down (running VMs only)
  unshare <vm> <name or folder>         Stop sharing a folder, at once if the VM is running
  clone <vm> [new name] [--keep-identity] [--include-snapshots] [--keep-suspended] [--no-identity-reset]
                                        Copy a stopped VM instantly (APFS clone); new identity unless kept
  delete <vm> --force                   Delete the VM and its disks
  echo-test <vm> [--bytes N]            Start the VM and round-trip bytes over the guest channel
  prepare-windows <vm> --user NAME --password PW [--virtio-iso PATH] [--agent PATH]
         [--computer-name N] [--edition "Windows 11 Pro"] [--product-key K] [--timezone TZ]
                                        Build and attach the unattended-install disk (untested on Windows)
  lifecycle-test <vm>                   Exercise start/pause/resume/stop/force-stop/crash handling
  agent-test <vm>                       Check the guest agent end to end (needs the agent-test seed)
  diagnostics <file.zip>                Collect logs, cleaned settings and system facts for support (no disks, no passwords)
  path                                  Print the library directory

  <vm> is a name, an ID, or a unique ID prefix. Set TANDEM_HOME to use another library directory.
"""

func openLibrary() -> VMLibrary {
    do {
        if let home = ProcessInfo.processInfo.environment["TANDEM_HOME"] {
            return try VMLibrary(rootDirectory: URL(fileURLWithPath: home))
        }
        return try VMLibrary()
    } catch { fail(error.localizedDescription) }
}

func cmdList(_ args: Args) {
    let listing = openLibrary().list()
    if args.flags.contains("json") {
        let data = try! ConfigCoding.encoder().encode(listing.bundles.map(\.config))
        print(String(decoding: data, as: UTF8.self))
        return
    }
    if listing.bundles.isEmpty { print("No VMs.") }
    for b in listing.bundles {
        let c = b.config
        print("\(c.id.uuidString.prefix(8).lowercased())  \(c.name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(c.guestOS.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)) \(c.engine.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)) \(c.cpuCount) cpu  \(c.memoryMiB) MiB")
    }
    for f in listing.failures { print("unreadable: \(f.url.path): \(f.reason)") }
}

func cmdCreate(_ args: Args) throws {
    guard args.positional.count == 1 else { fail("create needs a name") }
    guard let osName = args.options["os"], let os = GuestOS(rawValue: osName) else {
        fail("--os must be one of: \(GuestOS.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    var engine: EngineKind? = nil
    if let e = args.options["engine"] {
        guard let kind = EngineKind(rawValue: e) else { fail("--engine must be vz or qemu") }
        engine = kind
    }
    var config = VMConfig(name: args.positional[0], guestOS: os, engine: engine)
    if args.flags.contains("tpm") { config.tpm = true }
    if let n = args.int("cpus") { config.cpuCount = n }
    if let n = args.int("memory") { config.memoryMiB = n }
    if let n = args.int("disk") { config.disks[0].sizeGiB = n }
    for (key, kind) in [("iso", MediaKind.installerISO), ("seed", .seedISO)] {
        if let path = args.options[key] {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { fail("no such file: \(url.path)") }
            config.removableMedia.append(RemovableMedia(file: url.path, kind: kind))
        }
    }
    let bundle = try openLibrary().create(config)
    if let source = args.options["import-disk"] {
        // Replace the empty disk with a copy of an existing raw image (APFS clone when possible).
        let target = bundle.diskURL(bundle.config.disks[0])
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: target)
        let size = (try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? UInt64) ?? 0
        if bundle.config.disks[0].format == .raw, size < UInt64(bundle.config.disks[0].sizeGiB) << 30 {
            try DiskImage.growRaw(at: target, toGiB: bundle.config.disks[0].sizeGiB)
        }
    }
    print("Created \(bundle.config.name) (\(bundle.id.uuidString.lowercased()))\n\(bundle.url.path)")
}

func describe(_ vm: ParallelsVM) {
    print("\(vm.name)  (\(vm.kind.rawValue), \(vm.guestOS?.rawValue ?? "unsupported OS"), \(vm.cpuCount) cpu, \(vm.memoryMiB) MiB\(vm.hasTPM ? ", TPM" : ""))")
    for d in vm.disks {
        let used = d.images.reduce(UInt64(0)) { $0 + (((try? FileManager.default.attributesOfItem(atPath: $1.path))?[.size] as? UInt64) ?? 0) }
        print(String(format: "  disk  %@  %.0f GiB virtual, %.1f GiB file, %@, %d snapshot record(s)", d.directory.lastPathComponent,
                     Double(d.sizeBytes) / 1_073_741_824, Double(used) / 1_073_741_824, d.qemuFormat, d.snapshotCount))
    }
    if vm.blockers.isEmpty { print("  importable") } else { for b in vm.blockers { print("  BLOCKED: \(b)") } }
}

func freeBytes(at url: URL) -> UInt64 {
    UInt64((try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0)
}

func isoOption(_ args: Args, _ name: String) -> URL? {
    guard let path = args.options[name] else { return nil }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else { fail("no such file: \(url.path)") }
    return url
}

func cmdImportParallels(_ args: Args) async throws {
    guard let path = args.positional.first else { fail("import-parallels needs the path of a .pvm or .macvm") }
    let vm = try ParallelsVM.inspect(URL(fileURLWithPath: path))
    describe(vm)
    let options = ParallelsImporter.Options(name: args.options["name"], copy: args.flags.contains("copy"),
                                            windowsISO: isoOption(args, "windows-iso"), virtioISO: isoOption(args, "virtio-iso"))
    let result = try await ParallelsImporter.run(vm, options: options, library: openLibrary()) { print($0) }
    print("Imported \(result.bundle.config.name) (\(result.bundle.id.uuidString.lowercased()))\n\(result.bundle.url.path)")
    for note in result.notes { print("- \(note)") }
}

/// Set by `start --embedded`.
nonisolated(unsafe) var embeddedDisplay = false

@MainActor
func makeEngine(_ bundle: VMBundle, headless: Bool) -> any VMEngine {
    switch bundle.config.engine {
    case .vz: return VZEngine(bundle: bundle)
    case .qemu: return QEMUEngine(bundle: bundle, displayMode: embeddedDisplay ? .embedded : (headless ? .none : .cocoa))
    }
}

/// Writes B,G,R,X pixels as a PNG.
func writePNG(size: RFBClient.Size, pixels: Data, to url: URL) throws {
    guard size.width > 0, size.height > 0, let provider = CGDataProvider(data: pixels as CFData),
          let image = CGImage(width: size.width, height: size.height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: size.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw VMError("Cannot encode the screenshot.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw VMError("Cannot write \(url.path).") }
}

func cmdInput(_ args: Args) async throws {
    guard args.positional.count >= 2 else { fail("input needs a VM and at least one step") }
    let bundle = try openLibrary().find(args.positional[0])
    let path = QEMURunPaths.forVM(bundle.id).display
    guard FileManager.default.fileExists(atPath: path) else { fail("“\(bundle.config.name)” is not running with --embedded") }
    let client = try await RFBClient.connect(path: path, timeout: 5)
    defer { client.close() }
    client.start()
    for _ in 0..<50 where !client.supportsScancodes { try await Task.sleep(nanoseconds: 100_000_000) }
    let input = GuestInput(client: client)
    // The VM's own keyboard settings (Configure > Hardware > Mouse & Keyboard) apply to scripted input too.
    client.inputSettings = GuestInputSettings(bundle.config.behaviorOrDefault)
    func pause(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    func point(_ text: Substring) -> (Int, Int) {
        let parts = text.split(separator: ",").compactMap { Int($0) }
        guard parts.count == 2 else { fail("bad point “\(text)”") }
        return (parts[0], parts[1])
    }
    for step in args.positional.dropFirst() {
        guard let colon = step.firstIndex(of: ":") else { fail("bad step “\(step)”") }
        let value = step[step.index(after: colon)...]
        switch step[..<colon] {
        case "key":
            let codes = value.split(separator: "+").map { text -> UInt16 in
                guard let code = UInt16(text.hasPrefix("0x") ? String(text.dropFirst(2)) : String(text), radix: text.hasPrefix("0x") ? 16 : 10) else { fail("bad keycode “\(text)”") }
                return code
            }
            for code in codes { guard input.key(macKeyCode: code, down: true) else { fail("no PC key for mac keycode \(code)") }; try await pause(0.05) }
            for code in codes.reversed() { input.key(macKeyCode: code, down: false); try await pause(0.05) }
        case "type":
            for character in value.replacingOccurrences(of: "\\n", with: "\n") {
                guard let stroke = KeyMap.keystroke(for: character) else { fail("cannot type “\(character)”") }
                if stroke.shift { input.key(macKeyCode: 0x38, down: true) }
                input.key(macKeyCode: stroke.code, down: true); try await pause(0.02)
                input.key(macKeyCode: stroke.code, down: false)
                if stroke.shift { input.key(macKeyCode: 0x38, down: false) }
                try await pause(0.02)
            }
        case "move": let p = point(value); input.movePointer(toX: p.0, y: p.1)
        case "click", "rclick":
            let p = point(value); let button: RFBClient.Buttons = step.hasPrefix("r") ? .right : .left
            input.movePointer(toX: p.0, y: p.1); try await pause(0.1)
            input.setButton(button, down: true); try await pause(0.08); input.setButton(button, down: false)
        case "wait": try await pause(Double(value) ?? 1)
        default: fail("unknown step “\(step)”")
        }
        try await pause(0.15)
    }
}

func cmdScreenshot(_ args: Args) async throws {
    guard args.positional.count == 2 else { fail("screenshot needs a VM and an output path") }
    let bundle = try openLibrary().find(args.positional[0])
    let path = QEMURunPaths.forVM(bundle.id).display
    guard FileManager.default.fileExists(atPath: path) else { fail("“\(bundle.config.name)” is not running with --embedded") }
    let client = try await RFBClient.connect(path: path, timeout: 5)
    defer { client.close() }
    let updated = LockedBox(false)
    client.onUpdate = { updated.set(true) }
    client.start()
    // The first full frame arrives right after the handshake.
    for _ in 0..<50 where !updated.get() { try await Task.sleep(nanoseconds: 100_000_000) }
    try await Task.sleep(nanoseconds: 300_000_000)
    let shot = client.snapshot()
    try writePNG(size: shot.size, pixels: shot.pixels, to: URL(fileURLWithPath: args.positional[1]))
    print("\(shot.size.width)x\(shot.size.height) scancodes=\(client.supportsScancodes)")
}

/// resize <vm> <width>x<height>: ask a running --embedded VM to change its display size, then report what it did.
func cmdResize(_ args: Args) async throws {
    guard args.positional.count == 2 else { fail("resize needs a VM and a size such as 1600x1000") }
    let wanted = args.positional[1].split(separator: "x").compactMap { Int($0) }
    guard wanted.count == 2 else { fail("the size must look like 1600x1000") }
    let bundle = try openLibrary().find(args.positional[0])
    let path = QEMURunPaths.forVM(bundle.id).display
    guard FileManager.default.fileExists(atPath: path) else { fail("“\(bundle.config.name)” is not running with --embedded") }
    let client = try await RFBClient.connect(path: path, timeout: 5)
    defer { client.close() }
    client.start()
    for _ in 0..<30 where !client.supportsResizeRequests { try await Task.sleep(nanoseconds: 100_000_000) }
    print("before: \(client.size.width)x\(client.size.height) server accepts resize requests: \(client.supportsResizeRequests)")
    client.requestDesktopSize(width: wanted[0], height: wanted[1])
    for second in 1...Int(args.options["wait"] ?? "8")! {
        try await Task.sleep(nanoseconds: 1_000_000_000)
        print("after \(second)s: \(client.size.width)x\(client.size.height)")
    }
}

/// Runs the VM until it stops. Returns the process exit code.
@MainActor
func runForeground(_ bundle: VMBundle, headless: Bool = false, configure: (@MainActor (any VMEngine) -> Void)? = nil) async -> Int32 {
    let engine = makeEngine(bundle, headless: headless)
    let done = AsyncStream<VMState>.makeStream()
    engine.lifecycle.onChange = { state in
        print("state: \(state.rawValue)")
        if state == .stopped || state == .error { done.continuation.yield(state) }
    }
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    var interrupts = 0
    sigint.setEventHandler {
        interrupts += 1
        Task { @MainActor in
            if interrupts == 1 {
                print("Shutting down (Ctrl-C again to force)…")
                do { try await engine.requestStop() } catch { try? await engine.forceStop() }
            } else { try? await engine.forceStop() }
        }
    }
    sigint.resume()
    // SIGTERM and SIGHUP shut the guest down too, so a killed vmctl does not leave the VM behind.
    var sources: [DispatchSourceSignal] = []
    for number in [SIGTERM, SIGHUP] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { Task { @MainActor in do { try await engine.requestStop() } catch { try? await engine.forceStop() } } }
        source.resume(); sources.append(source)
    }
    // SIGUSR1 suspends the VM; SIGUSR2 takes its state as for a snapshot and lets it run on (tests).
    signal(SIGUSR1, SIG_IGN); signal(SIGUSR2, SIG_IGN)
    let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    usr1.setEventHandler { Task { @MainActor in
        print("Suspending…")
        do { try await engine.suspend(); print("suspended") } catch { print("suspend failed: \(error.localizedDescription)") }
    } }
    usr1.resume(); sources.append(usr1)
    let usr2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
    usr2.setEventHandler { Task { @MainActor in
        do {
            try await engine.prepareSnapshot()
            let size = (try? bundle.suspendStateURL?.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
            print("state saved (\((size ?? 0) / 1_048_576) MiB); continuing")
            try await engine.finishSnapshot()
            print("continued")
        } catch { print("state save failed: \(error.localizedDescription)") }
    } }
    usr2.resume(); sources.append(usr2)
    _ = sources
    if bundle.isSuspended { print("Resuming from the suspended state…") }
    configure?(engine)
    do { try await engine.start() }
    catch { FileHandle.standardError.write(Data("vmctl: \(error.localizedDescription)\n".utf8)); return 1 }
    if InstallProgress.needsInstallerBoot(bundle.config), let qemu = engine as? QEMUEngine {
        var started = bundle
        InstallProgress.markStarted(&started)
        print("install: starting Windows Setup from the install disc")
        Task { await qemu.pressKeyForInstallerBoot() }
    }
    for await state in done.stream {
        if state == .error {
            FileHandle.standardError.write(Data("vmctl: \(engine.lifecycle.lastError?.localizedDescription ?? "unknown error")\n".utf8))
            return 1
        }
        break
    }
    return 0
}

/// Spike 0.3: the guest connects, sends READY, then echoes. We send N random bytes and compare.
func echoTest(stream: GuestStream, bytes: Int) -> Bool {
    do {
        var buffer = Data()
        while buffer.range(of: Data("READY\n".utf8)) == nil {
            let d = try stream.read(max: 4096)
            if d.isEmpty { print("echo-test: stream closed before READY"); return false }
            buffer.append(d)
        }
        var payload = Data(count: bytes)
        payload.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        let start = Date()
        let writer = Thread { try? stream.write(payload) }
        writer.start()
        var received = Data()
        while received.count < bytes {
            let d = try stream.read(max: 65536)
            if d.isEmpty { break }
            received.append(d)
        }
        let seconds = Date().timeIntervalSince(start)
        let ok = received == payload
        print(String(format: "echo-test: sent %d recv %d match=%@ %.3fs %.1f MiB/s", bytes, received.count,
                     ok ? "true" : "false", seconds, Double(bytes) / seconds / 1_048_576))
        return ok
    } catch {
        print("echo-test: \(error.localizedDescription)")
        return false
    }
}

/// Integration check for Phase 1/2 acceptance: pause, resume, guest shutdown, force stop, crash detection.
@MainActor
func lifecycleTest(_ bundle: VMBundle) async -> Bool {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ note: String = "") {
        print("\(ok ? "PASS" : "FAIL")  \(name)\(note.isEmpty ? "" : "  (\(note))")")
        if !ok { failures += 1 }
    }
    func wait(for state: VMState, on engine: any VMEngine, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while engine.lifecycle.state != state && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
        return engine.lifecycle.state == state
    }
    func orphans(_ engine: any VMEngine) -> [Int32] { (engine as? QEMUEngine)?.processIdentifiers ?? [] }

    let engine = makeEngine(bundle, headless: true)
    do {
        try await engine.start(); check("start -> running", engine.lifecycle.state == .running)
        try await Task.sleep(nanoseconds: 20_000_000_000) // let the guest boot far enough to handle the power button
        try await engine.pause(); check("pause -> paused", engine.lifecycle.state == .paused)
        try await engine.resume(); check("resume -> running", engine.lifecycle.state == .running)
        try await engine.requestStop()
        let clean = await wait(for: .stopped, on: engine, seconds: 60)
        check("requestStop -> stopped (guest shut down by itself)", clean)
        if !clean { try await engine.forceStop() }
        try await Task.sleep(nanoseconds: 2_500_000_000)
        check("no processes left after stop", orphans(engine).isEmpty)

        try await engine.start(); check("restart -> running", engine.lifecycle.state == .running)
        try await engine.forceStop()
        check("forceStop -> stopped", await wait(for: .stopped, on: engine, seconds: 10))
        try await Task.sleep(nanoseconds: 2_500_000_000)
        check("no processes left after forceStop", orphans(engine).isEmpty)

        if let q = engine as? QEMUEngine {
            try await q.start()
            let pid = q.processIdentifiers.first ?? 0
            kill(pid, SIGKILL)
            let errored = await wait(for: .error, on: q, seconds: 10)
            check("killed QEMU -> error", errored, q.lifecycle.lastError?.message ?? "no error recorded")
            try await Task.sleep(nanoseconds: 2_500_000_000)
            check("no processes left after crash", q.processIdentifiers.isEmpty)
            try await q.start(); check("start again after error", q.lifecycle.state == .running)
            try await q.forceStop()
            _ = await wait(for: .stopped, on: q, seconds: 10)
        }
    } catch {
        check("unexpected error: \(error.localizedDescription)", false)
        try? await engine.forceStop()
    }
    print(failures == 0 ? "lifecycle-test: all checks passed" : "lifecycle-test: \(failures) check(s) failed")
    return failures == 0
}

/// Phase 4 integration check. The test guest (scripts/agent-test/seed) sets its clock wrong, starts the
/// agent, kills it after 15 s and starts it again. We expect: two HELLOs without a VM restart, guest info
/// with an IP address, a "clock stepped" log line, and a clean power-off when we send SHUTDOWN_REQUEST.
@MainActor
func agentTest(_ bundle: VMBundle) async -> Bool {
    let engine = makeEngine(bundle, headless: true)
    let link = GuestLinkHost()
    let hellos = LockedBox<[LinkSession.Hello]>([])
    let logs = LockedBox<[String]>([])
    let info = LockedBox<GuestInfo?>(nil)
    link.onHello = { h in hellos.set(hellos.get() + [h]); print("hello: agent \(h.agentVersion) os=\(h.os.map { "\($0)" } ?? "?") caps=\(h.capabilities)") }
    link.onGuestInfo = { i in info.set(i); print("guest info: \(i.hostname ?? "?") \(i.osName ?? "?") \(i.osVersion ?? "") kernel \(i.kernel ?? "?") ip \(i.ipAddresses ?? [])") }
    link.onLog = { level, message in logs.set(logs.get() + [message]); print("guest log[\(level)]: \(message)") }
    link.onDisconnect = { print("agent disconnected") }
    engine.onGuestStream = { link.attach($0) }

    var failures = 0
    func check(_ name: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL")  \(name)"); if !ok { failures += 1 } }
    func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 200_000_000) }
        return condition()
    }
    do {
        let started = Date()
        try await engine.start()
        check("agent says HELLO after boot", await waitUntil(120) { !hellos.get().isEmpty })
        print(String(format: "  (%.1f s after VM start)", Date().timeIntervalSince(started)))
        check("guest info includes an IP address", await waitUntil(15) { !(info.get()?.ipAddresses ?? []).isEmpty })
        check("guest clock was stepped to host time", await waitUntil(15) { logs.get().contains { $0.contains("clock stepped") } })
        check("agent reconnects after being killed (second HELLO, same VM run)", await waitUntil(60) { hellos.get().count >= 2 })
        check("VM stayed running throughout", engine.lifecycle.state == .running)
        try await Task.sleep(nanoseconds: 1_000_000_000) // let the new agent park its WAIT_EVENT
        link.requestGuestShutdown()
        check("SHUTDOWN_REQUEST event powers the guest off", await waitUntil(60) { engine.lifecycle.state == .stopped })
    } catch {
        check("unexpected error: \(error.localizedDescription)", false)
    }
    if engine.lifecycle.state != .stopped { try? await engine.forceStop() }
    print(failures == 0 ? "agent-test: all checks passed" : "agent-test: \(failures) check(s) failed")
    return failures == 0
}

/// Phase 3: builds the unattended-install disk for a Windows VM and attaches it.
func cmdPrepareWindows(_ args: Args) throws {
    guard let key = args.positional.first else { fail("prepare-windows needs a VM") }
    guard let user = args.options["user"] else { fail("prepare-windows needs --user (and optionally --password, --no-auto-login)") }
    let password = args.options["password"] ?? ""
    let library = openLibrary()
    var bundle = try library.find(key)
    guard bundle.config.guestOS == .windows11arm else { fail("“\(bundle.config.name)” is not a Windows VM") }
    var options = WindowsUnattendOptions(userName: user, password: password, autoLogin: !args.flags.contains("no-auto-login"))
    if let name = args.options["computer-name"] { options.computerName = name }
    if let edition = args.options["edition"] { options.edition = edition }
    if let productKey = args.options["product-key"] { options.productKey = productKey }
    if let tz = args.options["timezone"] { options.timeZone = tz }

    let virtio = args.options["virtio-iso"].map { URL(fileURLWithPath: $0) }
    if virtio == nil { print("warning: no --virtio-iso given; Windows will have no network or guest-agent channel after install") }
    let drivers = try WindowsInstall.prepare(&bundle, options: options, virtioISO: virtio,
                                             agent: args.options["agent"].map { URL(fileURLWithPath: $0) })
    if !drivers.isEmpty { print("Drivers: \(drivers.joined(separator: ", "))") }
    let iso = bundle.url.appendingPathComponent(UnattendMediaBuilder.fileName)
    print("Wrote \(iso.path) and attached it to \(bundle.config.name).")
}

setvbuf(stdout, nil, _IOLBF, 0) // line-buffered even when piped, so logs appear as they happen
MacOSRestoreImages.register() // "Download macOS" lives with the engine it needs
let raw = Array(CommandLine.arguments.dropFirst())
guard let command = raw.first else { print(usage); exit(0) }
let args = Args(Array(raw.dropFirst()))

do {
    switch command {
    case "list": cmdList(args)
    case "path": print(openLibrary().rootDirectory.path)
    case "show":
        guard let key = args.positional.first else { fail("show needs a VM") }
        let bundle = try openLibrary().find(key)
        print(bundle.url.path)
        print(String(decoding: try ConfigCoding.encoder().encode(bundle.config), as: UTF8.self))
    case "create":
        if let spec = args.options["download"] { try await cmdCreateDownloaded(args, spec: spec) } else { try cmdCreate(args) }
    case "download": try await cmdDownload(args)
    case "templates": try cmdTemplates(args)
    case "inspect-parallels":
        guard !args.positional.isEmpty else { fail("inspect-parallels needs a path") }
        for path in args.positional { describe(try ParallelsVM.inspect(URL(fileURLWithPath: path))) }
    case "import-parallels": try await cmdImportParallels(args)
    case "build-repair-media":
        // Debug aid: writes the Windows repair disk to a file.
        guard let out = args.positional.first else { fail("build-repair-media needs an output path") }
        var drivers: URL? = nil
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-repair-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        if let virtio = args.options["virtio-iso"] {
            drivers = scratch.appendingPathComponent("drivers")
            _ = try VirtioDrivers.collect(fromISO: URL(fileURLWithPath: virtio), to: drivers!)
        }
        try WindowsImportRepair.buildMedia(at: URL(fileURLWithPath: out), driversDirectory: drivers, agentExecutable: ParallelsImporter.defaultWindowsAgent)
        print(out)
    case "repair-windows-import":
        guard let key = args.positional.first else { fail("repair-windows-import needs a VM") }
        guard let iso = isoOption(args, "windows-iso") else { fail("--windows-iso is required") }
        _ = try await ParallelsImporter.repairWindows(try openLibrary().find(key), windowsISO: iso, virtioISO: isoOption(args, "virtio-iso")) { print($0) }
        print("Windows repair finished.")
    case "clone":
        // clone <vm> [new name] [--keep-identity] [--include-snapshots] [--keep-suspended] [--no-identity-reset]
        guard let key = args.positional.first else { fail("clone needs a VM") }
        let library = openLibrary()
        let source = try library.find(key)
        if let record = source.readRunRecord(), record.hostIsAlive {
            fail("“\(source.config.name)” is running (in \(record.hostName), process \(record.hostPID)). Shut it down or suspend it first.")
        }
        // The claim on the source for the copy: no start, revert or second clone meanwhile.
        let lease = try BundleLease.acquire(source, purpose: "being cloned")
        defer { lease.release() }
        let options = CloneOptions(name: args.positional.dropFirst().first, includeSnapshots: args.flags.contains("include-snapshots"),
                                   keepSuspendState: args.flags.contains("keep-suspended"),
                                   keepHardwareIdentity: args.flags.contains("keep-identity"),
                                   resetGuestIdentity: !args.flags.contains("no-identity-reset"))
        let freeBefore = VMCloner.freeBytes(at: library.vmsDirectory)
        let began = Date()
        let clone = try VMCloner.clone(source, into: library.vmsDirectory, taken: Set(library.list().bundles.map(\.config.name)),
                                       options: options, hooks: CloneSupport.hooks(qemuImg: try? QEMUToolchain.locate().qemuImg))
        let used = max(0, freeBefore - VMCloner.freeBytes(at: library.vmsDirectory))
        print("Cloned \(source.config.name) as \(clone.config.name) (\(clone.id.uuidString.prefix(8).lowercased())) in \(String(format: "%.1f", Date().timeIntervalSince(began))) s")
        print("  disk space used: about \(used / 1_048_576) MiB now (blocks are shared until either VM changes them)")
        print("  identity: \(options.keepHardwareIdentity ? "kept (do not run both at once)" : "new firmware UUID, TPM and MAC address")"
              + (clone.config.pendingGuestIdentityReset == true ? "; guest identity reset at first start" : ""))
    case "delete":
        guard let key = args.positional.first else { fail("delete needs a VM") }
        guard args.flags.contains("force") else { fail("delete removes the VM's disks. Pass --force to confirm.") }
        let library = openLibrary()
        let bundle = try library.find(key)
        try BundleLease.with(bundle, purpose: "being deleted") { _ in try library.delete(bundle) }
        print("Deleted \(bundle.config.name)")
    case "share-serve":
        // share-serve <folder> [--name N] [--port P] [--any-host] [--read-only]: publish a folder until interrupted (for testing).
        guard let folder = args.positional.first else { fail("share-serve needs a folder") }
        let server = WebDAVServer(shares: [.init(name: args.options["name"] ?? "Mac", root: URL(fileURLWithPath: folder), readOnly: args.flags.contains("read-only"))],
                                  requiredHost: args.flags.contains("any-host") ? nil : "10.0.2.2")
        server.onLog = { line in FileHandle.standardError.write(Data((line + "\n").utf8)) }
        let port = try server.start(port: UInt16(args.options["port"] ?? "0") ?? 0)
        print("Serving \(folder) on 127.0.0.1:\(port); a QEMU guest opens \\\\10.0.2.2@\(port)\\DavWWWRoot")
        fflush(stdout)
        while true { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
    case "snapshot":
        // snapshot <vm> [list] | take <name> | revert <name or id> | delete <name or id>
        guard let key = args.positional.first else { fail("snapshot needs a VM") }
        let bundle = try openLibrary().find(key)
        let store = SnapshotStore(bundle: bundle)
        let action = args.positional.dropFirst().first ?? "list"
        let value = args.positional.dropFirst(2).joined(separator: " ")
        func pick() -> VMSnapshot {
            let all = store.list()
            guard let found = all.first(where: { $0.id.uuidString.lowercased().hasPrefix(value.lowercased()) && !value.isEmpty })
                    ?? all.first(where: { $0.name == value }) else { fail("no snapshot named or numbered \(value)") }
            return found
        }
        switch action {
        case "list":
            for s in store.list() { let z = store.size(of: s.id); print("\(s.id.uuidString.prefix(8).lowercased())  \(ISO8601DateFormatter().string(from: s.created))  \(z.total / 1_048_576) MiB (\(z.exclusive / 1_048_576) MiB exclusive)  \(s.name)") }
        // Each change holds the VM's lease, so it is refused while the VM runs anywhere (the app included).
        case "take":
            let s = try BundleLease.with(bundle, purpose: "taking a snapshot") { _ in try store.create(name: value, config: bundle.config) }
            print("Took snapshot \(s.name) (\(s.id.uuidString.prefix(8).lowercased()))")
        case "revert":
            let s = pick(); try BundleLease.with(bundle, purpose: "going back to a snapshot") { _ in try store.revert(to: s.id) }
            print("Went back to \(s.name)")
        case "delete":
            let s = pick(); try BundleLease.with(bundle, purpose: "deleting a snapshot") { _ in try store.delete(s.id) }
            print("Deleted snapshot \(s.name)")
        default: fail("snapshot actions: list, take, revert, delete")
        }
    case "start":
        guard let key = args.positional.first else { fail("start needs a VM") }
        var bundle = try openLibrary().find(key)
        // --share <folder> shares one more folder for this run only (a temporary grant; add --read-only);
        // the saved configuration is not changed.
        var grants = TemporaryGrants()
        if let folder = args.options["share"] {
            grants.folders = [SharedFolder(hostPath: URL(fileURLWithPath: folder).standardizedFileURL.path, name: "Test", readOnly: args.flags.contains("read-only"))]
        }
        // The VM's sharing policy, kept current while it runs: `vmctl sharing/share/unshare` and the app's
        // settings panel change the files it watches.
        let sharing = SharingRuntime(bundle: bundle, initialGrants: grants)
        sharing.start()
        // Folders that are devices (Linux) are attached at start, so the engine must see the temporary one too.
        bundle.config.sharedFolders = sharing.policy.folders.map(\.folder)
        embeddedDisplay = args.flags.contains("embedded")
        // Print guest agent activity, so a start also shows whether the agent connected.
        let link = GuestLinkHost()
        nonisolated(unsafe) var installing = bundle
        nonisolated(unsafe) var cloneIdentity = bundle
        link.onHello = { h in
            print("agent: hello, version \(h.agentVersion), capabilities \(h.capabilities)")
            if cloneIdentity.config.pendingGuestIdentityReset == true {
                Task { if let line = await link.resetCloneIdentityIfNeeded(&cloneIdentity, capabilities: h.capabilities) { print(line) } }
            }
            if installing.config.guestOS != .windows11arm {
                if InstallProgress.markComplete(&installing) { print("install: first start complete; the setup disc is deleted") }
            } else if InstallProgress.markComplete(&installing) { print("install: complete; shut the VM down and start it again to switch to the resizable display (the app does this by itself)") }
        }
        link.onGuestInfo = { i in print("agent: guest \(i.hostname ?? "?") \(i.osName ?? "?") \(i.osVersion ?? "") ip \(i.ipAddresses ?? [])") }
        link.onLog = { level, message in print("agent log[\(level)]: \(message)") }
        link.onDisconnect = { print("agent: disconnected") }
        // Shared folders: the VM's own, or one test folder with --share <folder>.
        let folders = SharedFolderService()
        let shareConfig = bundle.config
        folders.onLog = { line in print("share: \(line)") }
        try folders.start(config: shareConfig, policy: sharing.policy)
        if folders.port != 0 { print("share: serving \(folders.names) on port \(folders.port)") }
        link.clipboardPolicy = { sharing.policy.clipboard }
        nonisolated(unsafe) var runningEngine: (any VMEngine)?
        /// Stops the published services; set once they exist, further down.
        nonisolated(unsafe) var inboundClosed: (() -> Void)?
        sharing.onChange = { old, new in
            Task { @MainActor in
                var devicesUpdated = false
                if let vz = runningEngine as? VZEngine, old.folders != new.folders {
                    devicesUpdated = (try? vz.updateSharedFolders(new.folders.map(\.folder))) ?? false
                }
                let change = folders.apply(new, devicesUpdated: devicesUpdated)
                if change.announce { link.notifySharesChanged() }
                print("sharing: now \(new.folders.map { $0.name + ($0.folder.readOnly ? " (read-only)" : "") + ($0.temporary ? " (until shutdown)" : "") }), clipboard \(new.clipboard.rawValue), usb \(new.usbAllowed ? "allowed" : "not allowed")")
                if let deferred = change.deferred { print("sharing: \(deferred)") }
                if !change.revokedDevices.isEmpty, let qemu = runningEngine as? QEMUEngine {
                    // Give the guest tools a moment to unmount, then pull the devices so nothing can mount them again.
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    let gone = await qemu.detachSharedFolders(change.revokedDevices)
                    print("sharing: removed \(gone.count) of \(change.revokedDevices.count) folder device(s) from the running VM")
                }
                if let qemu = runningEngine as? QEMUEngine {
                    let taken = await qemu.enforceUSB(new)
                    if !taken.isEmpty { print("sharing: took \(taken.count) USB device(s) back from the VM") }
                }
                if old.allowsInboundServices && !new.allowsInboundServices {
                    inboundClosed?()
                    let closed = await (runningEngine as? QEMUEngine)?.closeInboundForwards() ?? 0
                    print("sharing: connections into the VM are no longer allowed; closed \(closed) forwarded port(s) and the published services")
                }
            }
        }
        if !args.flags.contains("no-agent-update") { link.agentBinary = { os in os == .windows ? GuestTools.windowsAgent : os == .linux ? GuestTools.linuxAgent : nil } }
        let printInfo = link.onGuestInfo
        link.onGuestInfo = { i in printInfo?(i); folders.setGuestUTCOffset(i.utcOffsetSeconds) }
        link.shares = { SharesInfo(kind: folders.kind, port: folders.port, shares: folders.names) }
        link.onDisplayReport = { r in print("agent: display \(r.width)x\(r.height) result \(r.result)") }
        // What the idle timer goes by: the guest's own account of how much it is in use.
        link.onActivity = { a in
            print("agent: activity idle \(a.idleSeconds.map { "\($0) s" } ?? "unknown"), processor \(a.cpuPercent.map { "\($0)%" } ?? "unknown"), keep awake \(a.keepAwake)")
        }
        // --test-delay N: seconds between the agent connecting and the clipboard and resize tests (a desktop
        // guest needs time for someone to sign in first). Defaults: 8 s for the clipboard, 20 s for resizing.
        let testDelay = Double(args.options["test-delay"] ?? "")
        if let sizeText = args.options["resize-test"] {
            // After the agent connects: ask QEMU for a new display size, then ask the agent to switch to it.
            let wanted = sizeText.split(separator: "x").compactMap { Int($0) }
            let hello = link.onHello
            let displayPath = QEMURunPaths.forVM(bundle.id).display
            link.onHello = { h in
                hello?(h)
                Task {
                    try? await Task.sleep(nanoseconds: UInt64((testDelay ?? 20) * 1_000_000_000))
                    guard wanted.count == 2, let client = try? await RFBClient.connect(path: displayPath, timeout: 5) else { print("resize-test: no display"); return }
                    client.start()
                    for _ in 0..<30 where !client.supportsResizeRequests { try? await Task.sleep(nanoseconds: 100_000_000) }
                    client.requestDesktopSize(width: wanted[0], height: wanted[1])
                    print("resize-test: asked the display for \(wanted[0])x\(wanted[1])")
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    link.requestDisplayResize(width: wanted[0], height: wanted[1])
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    print("resize-test: display is now \(client.size.width)x\(client.size.height)")
                    client.close()
                }
            }
        }
        if args.flags.contains("clipboard-test") {
            // An in-memory clipboard, so the test never touches the Mac's real one.
            let fake = TestClipboard()
            link.clipboard = fake
            let hello = link.onHello
            link.onHello = { h in
                hello?(h)
                DispatchQueue.global().asyncAfter(deadline: .now() + (testDelay ?? 8)) {
                    fake.setText("tandem-host-to-guest-OK")
                    link.notifyClipboardChanged("tandem-host-to-guest-OK")
                    print("clipboard: host sent “tandem-host-to-guest-OK”")
                }
            }
        }
        if args.flags.contains("windows-test") {
            // Print the guest's window list whenever it changes.
            link.onWindowReport = { list in
                print("windows: desktop \(list.desktop[0])x\(list.desktop[1]), \(list.windows.count) windows, front first")
                for w in list.windows {
                    print("  \(w.kind.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(w.state.rawValue.prefix(3)) \(w.active ? "*" : " ") \(w.x),\(w.y) \(w.width)x\(w.height) id \(w.id) \(w.app) [\(w.class)] “\(w.title)”")
                }
            }
            let hello = link.onHello
            link.onHello = { h in
                hello?(h)
                guard h.capabilities & 64 != 0 else { print("windows-test: this agent cannot list windows"); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { link.watchWindows(true); print("windows-test: watching") }
            }
        }
        if args.flags.contains("programs-test") {
            // List the guest's programs, fetch the icons of the first few and of every program window,
            // and with --launch <name> start one. --icon-dir <folder> keeps the icons as PNG files.
            let iconDirectory = args.options["icon-dir"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            let wanted = args.options["launch"]
            link.onProgramList = { programs in
                print("programs: \(programs.count) listed")
                for program in programs.prefix(12) { print("  \(program.name)  [\(program.id)]") }
                for program in programs.prefix(6) { link.requestIcon(.program(program.id), size: 48) }
                if let wanted, let program = programs.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) {
                    link.requestIcon(.program(program.id), size: 48)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                        link.launchProgram(id: program.id)
                        print("programs: asked the guest to start \(program.name)")
                    }
                } else if let wanted { print("programs: no program named \(wanted)") }
                // --open-doc <share>/<path> [--open-with <program name>] [--open-after <seconds>]: ask what the
                // program opens, then open the shared document in it (or in its default program).
                if let document = args.options["open-doc"] {
                    let name = args.options["open-with"]
                    let program = name.flatMap { n in programs.first { $0.name.caseInsensitiveCompare(n) == .orderedSame } }
                    if let name, program == nil { print("open: no program named \(name)"); return }
                    if let program { link.requestProgramInfo(id: program.id) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + (Double(args.options["open-after"] ?? "") ?? 12)) {
                        print("open: asking the guest to open \(document) in \(program?.name ?? "its default program")")
                        link.openDocuments(request: 7, program: program?.id ?? "", documents: [document])
                    }
                }
            }
            link.onProgramInfo = { info, logo in
                print("program info: [\(info.id)] target “\(info.target)” logo \(logo.count) bytes, opens \(info.extensions.count) types: \(info.extensions.prefix(40).joined(separator: " "))")
                if let iconDirectory, !logo.isEmpty {
                    try? FileManager.default.createDirectory(at: iconDirectory, withIntermediateDirectories: true)
                    try? logo.write(to: iconDirectory.appendingPathComponent("logo.png"))
                }
            }
            link.onDocumentResult = { result in
                print("open: request \(result.request) \(result.status) \(result.message)")
            }
            link.onIcon = { icon in
                let opaque = stride(from: 3, to: icon.pixels.count, by: 4).filter { icon.pixels[icon.pixels.startIndex + $0] != 0 }.count
                print("icon: \(icon.key) \(icon.width)x\(icon.height), \(opaque) pixels with some opacity")
                guard let iconDirectory, let image = icon.cgImage,
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
                try? FileManager.default.createDirectory(at: iconDirectory, withIntermediateDirectories: true)
                let name = "\(icon.key)".map { $0.isLetter || $0.isNumber ? $0 : "_" }
                try? png.write(to: iconDirectory.appendingPathComponent(String(name.suffix(60)) + ".png"))
            }
            let report = link.onWindowReport
            nonisolated(unsafe) var asked = Set<UInt64>()
            link.onWindowReport = { list in
                report?(list)
                for window in list.windows where window.kind == .app && asked.insert(window.id).inserted {
                    link.requestIcon(.window(window.id), size: 128)
                }
            }
            let hello = link.onHello
            link.onHello = { h in
                hello?(h)
                guard h.capabilities & 128 != 0 else { print("programs-test: this agent cannot list programs"); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { link.requestPrograms(); link.watchWindows(true) }
            }
        }
        if let script = args.options["exec-script"] {
            // Tests: once the guest tools first connect, run each line of a file in the guest, one after the
            // other, and print what it printed. A line starting with "!" runs elevated (Windows); blank lines
            // and lines starting with "#" are skipped. Works with any display, including a 3D one with no VNC.
            let lines = ((try? String(contentsOfFile: script, encoding: .utf8)) ?? "")
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            let delay = Double(args.options["exec-delay"] ?? "") ?? 20
            let hello = link.onHello
            nonisolated(unsafe) var started = false
            link.onHello = { h in
                hello?(h)
                guard !started else { return }
                started = true
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    for line in lines {
                        let elevated = line.hasPrefix("!")
                        let command = elevated ? String(line.dropFirst()) : line
                        print("exec\(elevated ? " (elevated)" : ""): \(command)")
                        do {
                            let r = try await link.exec(GuestExecRequest(command: command, elevated: elevated, timeoutSeconds: 600))
                            let out = String(decoding: r.stdout, as: UTF8.self), err = String(decoding: r.stderr, as: UTF8.self)
                            print("exec: status \(r.status) exit \(r.exitCode)\(r.message.isEmpty ? "" : " (\(r.message))")")
                            if !out.isEmpty { print(out) }
                            if !err.isEmpty { print("stderr: \(err)") }
                        } catch { print("exec: failed: \(error.localizedDescription)") }
                    }
                    print("exec-script: done")
                }
            }
        }
        if args.flags.contains("restart-test") {
            // Ten seconds after the agent first connects, ask the guest to restart; it should connect again.
            let hello = link.onHello
            nonisolated(unsafe) var asked = false
            link.onHello = { h in
                hello?(h)
                guard !asked else { print("restart-test: the agent is back after the restart"); return }
                asked = true
                guard h.capabilities & 32 != 0 else { print("restart-test: this agent cannot restart the guest"); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                    link.requestGuestRestart()
                    print("restart-test: asked the guest to restart")
                }
            }
        }
        if let port = args.options["serial-test"] {
            // Tests: once the guest tools connect, hand a serial port on the Mac (a real /dev/cu.* or a
            // pseudo-terminal) to the guest the way Devices > USB does, with the ids from --serial-ids vid:pid.
            let ids = (args.options["serial-ids"] ?? "0483:5740").split(separator: ":").compactMap { Int($0, radix: 16) }
            var device = HostUSBDevice(vendorID: ids.first ?? 0x0483, productID: ids.count > 1 ? ids[1] : 0x5740,
                                       name: "Tandem Serial Test", vendor: "Tandem Test", location: 0x7a7a0000)
            device.serialPath = port
            device.serialNumber = "TANDEM0001"
            let testDevice = device
            let policy = SharingPolicy(bundle.config)
            let hello = link.onHello
            nonisolated(unsafe) var attached = false
            link.onHello = { h in
                hello?(h)
                guard !attached else { return }
                attached = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    Task { @MainActor in
                        guard let qemu = runningEngine as? QEMUEngine else { print("serial-test: not a QEMU VM"); return }
                        let cdc = await qemu.qemuHasDevice(USBPassthroughPlan.cdcACMDevice)
                        do {
                            try await qemu.attachUSB(testDevice, policy: policy)
                            print("serial-test: attached \(port) as \(cdc ? "usb-cdc-acm" : "usb-serial (FTDI)"), ids \(String(format: "%04x:%04x", testDevice.vendorID, testDevice.productID)), in the VM: \(await qemu.usbIsAttached(testDevice))")
                            // --serial-guest-script FILE: a PowerShell script run in the guest once the port is there.
                            if let file = args.options["serial-guest-script"], let script = try? String(contentsOfFile: file, encoding: .utf8) {
                                try await Task.sleep(nanoseconds: 10_000_000_000)
                                let encoded = Data(script.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }).base64EncodedString()
                                let result = try await link.exec(GuestExecRequest(command: "powershell -NoProfile -EncodedCommand \(encoded)", timeoutSeconds: 120))
                                print("serial-test: guest script exit \(result.exitCode)")
                                print(String(decoding: result.stdout, as: UTF8.self))
                                let errors = String(decoding: result.stderr, as: UTF8.self)
                                if !errors.isEmpty { print("serial-test: guest stderr: \(errors.prefix(2000))") }
                            }
                        } catch {
                            print("serial-test: attach failed: \(error.localizedDescription) \((error as? VMError)?.detail ?? "")")
                        }
                    }
                }
            }
        }
        // --host-port N stands in for the shared folder server's port (tests).
        let hostPort = Int(args.options["host-port"] ?? "") ?? folders.port
        // Published services: the Mac listens for as long as this VM runs.
        let publisher = ServicePublisher(statusDirectory: ServicePublisher.statusDirectory(inLibraryRoot: openLibrary().rootDirectory))
        publisher.onLog = { line in print("services: \(line)") }
        inboundClosed = { publisher.stop() }
        let backends = ServicePublisher.needsBackends(bundle.config) ? ServicePublisher.backendPorts(for: bundle.config.publishedServices ?? []) : [:]
        let serviceConfig = bundle.config
        let code = await runForeground(bundle, headless: args.flags.contains("headless")) { engine in
            runningEngine = engine
            engine.onGuestStream = { link.attach($0) }
            (engine as? QEMUEngine)?.hostServicePort = hostPort
            (engine as? QEMUEngine)?.serviceBackends = backends
            if !(serviceConfig.publishedServices ?? []).isEmpty {
                LocalNames.startResponder()
                publisher.start(config: serviceConfig, target: ServicePublisher.target(config: serviceConfig, backends: backends) { link.guestInfo?.ipAddresses })
            }
        }
        publisher.stop()
        // Temporary access ends with the VM.
        sharing.stop()
        exit(code)
    case "sharing": try cmdSharing(args)
    case "share": try cmdShare(args)
    case "unshare": try cmdUnshare(args)
    case "screenshot": try await cmdScreenshot(args)
    case "resize": try await cmdResize(args)
    case "input": try await cmdInput(args)
    case "echo-test":
        guard let key = args.positional.first else { fail("echo-test needs a VM") }
        let bundle = try openLibrary().find(key)
        let bytes = args.int("bytes") ?? 1 << 20
        let result = LockedBox<Bool?>(nil)
        let code = await runForeground(bundle, headless: true) { engine in
            engine.onGuestStream = { stream in
                Thread.detachNewThread {
                    let ok = echoTest(stream: stream, bytes: bytes)
                    result.set(ok)
                    stream.close()
                    Task { @MainActor in try? await engine.forceStop() }
                }
            }
            // Give up if the guest never connects.
            DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
                if result.get() == nil {
                    print("echo-test: no guest connection within 180 s")
                    Task { @MainActor in try? await engine.forceStop() }
                }
            }
        }
        exit(code == 0 && result.get() == true ? 0 : 1)
    case "lifecycle-test":
        guard let key = args.positional.first else { fail("lifecycle-test needs a VM") }
        exit(await lifecycleTest(try openLibrary().find(key)) ? 0 : 1)
    case "prepare-windows": try cmdPrepareWindows(args)
    case "linux-tools-iso":
        // Builds the Linux guest tools disc: vmctl linux-tools-iso [--agent <file>] [--out <iso>]
        let agent = args.options["agent"].map { URL(fileURLWithPath: $0) } ?? GuestTools.linuxAgent
        guard let iso = try GuestTools.linuxISO(agent: agent, output: args.options["out"].map { URL(fileURLWithPath: $0) }) else {
            fail("no Linux agent build found; run scripts/build-agent.sh")
        }
        print(iso.path)
    case "guest-app-test":
        // Writes a stand-in app for a made-up guest program with the real writer, starts it the way
        // Tandem does, reports what it posts when chosen, and tells it to quit after 15 seconds.
        guard let folder = args.positional.first else { fail("guest-app-test needs a folder to write into") }
        let stub = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent(GuestAppBundle.executableName)
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.1, green: 0.5, blue: 1, alpha: 1)
        context.fillEllipse(in: CGRect(x: 4, y: 4, width: 56, height: 56))
        let vm = UUID()
        let bundle = try GuestAppBundle.write(in: GuestAppBundle.directory(root: URL(fileURLWithPath: folder), vmName: "Test VM"),
                                              name: "Test Program", vm: vm, program: "app:test.exe", icon: context.makeImage(), stub: stub)
        let sign = try ToolRun.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", bundle.path], timeout: ToolRun.Limit.quick)
        print("written and signed (\(sign.status)): \(bundle.path)")
        let center = DistributedNotificationCenter.default()
        let bundleID = GuestAppBundle.bundleIdentifier(vm: vm, program: "app:test.exe")
        for name in [GuestAppBundle.activateNotification, GuestAppBundle.closeNotification] {
            center.addObserver(forName: Notification.Name(name), object: bundleID, queue: .main) { note in
                print("stand-in posted \(name): \(note.userInfo ?? [:])")
            }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = [String(ProcessInfo.processInfo.processIdentifier)]
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { app, error in
            print("started: \(app?.localizedName ?? "nil") pid \(app?.processIdentifier ?? 0) error \(error?.localizedDescription ?? "none")")
        }
        try await Task.sleep(nanoseconds: 15_000_000_000)
        print("running before quit: \(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count)")
        center.postNotificationName(Notification.Name(GuestAppBundle.quitNotification), object: bundleID, userInfo: nil, deliverImmediately: true)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        print("running after quit: \(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count)")
    case "compact":
        // Free up disk space: rewrite the VM's qcow2 disks without what the guest has freed (VM stopped).
        guard let key = args.positional.first else { fail("compact needs a VM") }
        let bundle = try openLibrary().find(key)
        guard !FileManager.default.fileExists(atPath: QEMURunPaths.forVM(bundle.id).qmp), !bundle.isSuspended else {
            fail("“\(bundle.config.name)” is running or suspended; shut it down first")
        }
        for disk in DiskMaintenance.usage(of: bundle) {
            print("\(disk.file): \(disk.allocatedBytes / 1_048_576) MiB on this Mac of \(disk.virtualBytes / 1_048_576) MiB\(disk.canCompact ? "" : " (not a qcow2 disk; nothing to do)")")
        }
        let freed = try BundleLease.with(bundle, purpose: "having its disk compacted") { _ in
            try DiskMaintenance.compact(bundle: bundle, toolchain: try QEMUToolchain.locate())
        }
        print(freed > 0 ? "Freed \(freed / 1_048_576) MiB." : "Nothing to free.")
    case "diagnostics":
        // vmctl diagnostics <file.zip>: the same bundle as Help > Collect Diagnostics… in the app.
        guard let path = args.positional.first else { fail("diagnostics needs a path for the zip file") }
        var extra: [String: String] = [:]
        extra["QEMU"] = (try? QEMUToolchain.locate()).map { $0.qemuVersion } ?? "not found"
        extra["Helper"] = NetHelper.isInstalled ? ((try? NetHelper.info()).map { "protocol \($0.version), \($0.features.joined(separator: ", "))" } ?? "installed, not answering") : "not installed"
        let zip = try Diagnostics.collect(library: openLibrary(), extraInfo: extra, to: URL(fileURLWithPath: path))
        print("Wrote \(zip.path)")
        print("Contains: \(Diagnostics.contentsDescription)")
    case "usb-list":
        for d in HostUSBDevice.list() { print(String(format: "%04x:%04x  %@%@  — %@", d.vendorID, d.productID, d.name, d.vendor.map { "  (\($0))" } ?? "", d.routeLabel)) }
    case "usb-probe":
        // vmctl usb-probe <diskN>: what macOS lets the helper (root) do with that disk; changes nothing.
        guard let bsd = args.positional.first else { fail("usb-probe needs a disk name, for example disk5 (see: diskutil list external)") }
        guard NetHelper.isInstalled else { fail("the Tandem helper is not installed (sudo scripts/install-net-helper.sh)") }
        let probe = try NetHelper.diskProbe(bsd: bsd)
        for line in probe.report { print(line) }
        exit(probe.canServe ? 0 : 1)
    case "net-helper":
        // Reports whether the bridged-networking helper is installed and which interfaces it offers.
        guard NetHelper.isInstalled else { print("not installed (sudo scripts/install-net-helper.sh)"); break }
        print("installed; interfaces: \(try NetHelper.interfaces().joined(separator: ", "))")
    case "agent-test":
        guard let key = args.positional.first else { fail("agent-test needs a VM") }
        exit(await agentTest(try openLibrary().find(key)) ? 0 : 1)
    case "publish":
        // vmctl publish <vm> <name> --guest-port N [--host-port N] [--lan]
        guard args.positional.count == 2, let guestPort = args.int("guest-port") else { fail("publish needs a VM, a service name and --guest-port") }
        let library = openLibrary()
        var bundle = try library.find(args.positional[0])
        let others = Set(library.list().bundles.filter { $0.id != bundle.id }.flatMap { $0.config.publishedServices ?? [] }.map(\.hostPort))
        let service = try PublishedServices.publish(name: args.positional[1], guestPort: guestPort, hostPort: args.int("host-port"),
                                                    scope: args.flags.contains("lan") ? .lan : .mac, in: &bundle.config,
                                                    takenElsewhere: others, isFree: { ServiceRelay.portIsFree($0) })
        try bundle.save()
        if let wanted = args.int("host-port"), wanted != service.hostPort { print("Port \(wanted) was not available; using \(service.hostPort).") }
        else if args.int("host-port") == nil, service.hostPort != guestPort { print("Port \(guestPort) on the Mac is taken; using \(service.hostPort).") }
        print("Published “\(service.name)” of \(bundle.config.name): \(LocalNames.address(for: service, vmName: bundle.config.name)) → guest port \(service.guestPort) (\(service.scope.label.lowercased())).")
        print("It is served while the VM runs; a VM that is running now picks it up at its next start.")
        if !LocalNames.isInstalled { print("To use the name \(PublishedServices.hostName(forVMNamed: bundle.config.name)) as well, run once:\n  \(LocalNames.installCommand)") }
    case "unpublish":
        guard args.positional.count == 2 else { fail("unpublish needs a VM and a service name") }
        var bundle = try openLibrary().find(args.positional[0])
        guard PublishedServices.unpublish(name: args.positional[1], in: &bundle.config) else { fail("“\(bundle.config.name)” has no service named “\(args.positional[1])”") }
        try bundle.save()
        print("Removed “\(args.positional[1])” from \(bundle.config.name). A VM that is running now stops serving it at its next start.")
    case "services":
        // What is configured for each VM, and what is being served right now (by any Tandem process).
        let library = openLibrary()
        let bundles = try args.positional.first.map { [try library.find($0)] } ?? library.list().bundles
        let active = ServicePublisher.active(in: ServicePublisher.statusDirectory(inLibraryRoot: library.rootDirectory),
                                             knownVMs: Set(library.list().bundles.map(\.id)))
        let names = LocalNames.isInstalled
        struct Row: Codable { var vm, name, address, state: String; var hostPort, guestPort: Int; var scope: String; var error: String? }
        var rows: [Row] = []
        for bundle in bundles {
            let live = active.first { $0.vmID == bundle.id }
            for service in bundle.config.publishedServices ?? [] {
                let status = live?.services.first { $0.service == service }
                rows.append(Row(vm: bundle.config.name, name: service.name, address: LocalNames.address(for: service, vmName: bundle.config.name, namesInstalled: names),
                                state: status == nil ? "not running" : status!.isListening ? "serving" : "failed",
                                hostPort: service.hostPort, guestPort: service.guestPort, scope: service.scope.rawValue, error: status?.error))
            }
        }
        if args.flags.contains("json") {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(rows), as: UTF8.self))
        } else if rows.isEmpty {
            print("No services are published.")
        } else {
            for row in rows {
                print("\(row.vm)  \(row.name)  \(row.address) → guest port \(row.guestPort)  \(row.scope == "lan" ? "Mac and local network" : "this Mac only")  \(row.state)\(row.error.map { ": \($0)" } ?? "")")
            }
            if !names { print("Names under \(PublishedServices.domain) are not switched on; the addresses above work in browsers and curl. To switch them on:\n  \(LocalNames.installCommand)") }
        }
    case "check":
        // What this Mac can do for a VM of the given system and engine, before one is made.
        guard let os = GuestOS(rawValue: args.options["os"] ?? "windows11arm") else {
            fail("--os must be one of: \(GuestOS.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        var checkEngine: EngineKind? = nil
        if let e = args.options["engine"] { guard let kind = EngineKind(rawValue: e) else { fail("--engine must be vz or qemu") }; checkEngine = kind }
        var architecture = GuestArchitecture(rawValue: args.options["arch"] ?? "arm64")
        if let iso = args.options["iso"] {
            let guess = InstallerImage.inspect(URL(fileURLWithPath: iso))
            if let found = guess.architecture { architecture = found }
            if !args.flags.contains("json") { print("Install disc: \(guess.architecture?.label ?? "processor type not recognised")\(guess.evidence.map { " (from the \($0))" } ?? "")") }
        }
        guard let architecture else { fail("--arch must be arm64 or x86_64") }
        let request = CompatibilityRequest(guestOS: os, architecture: architecture, engine: checkEngine,
                                           memoryMiB: args.int("memory"), cpuCount: args.int("cpus"), neededDiskGiB: args.int("disk"))
        let report = Compatibility.evaluate(host: HostProbe.current(vmFolder: openLibrary().vmsDirectory), request: request)
        if args.flags.contains("json") {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else {
            print(report.text())
        }
        if !report.canProceed { exit(2) }
    case "help", "--help", "-h": print(usage)
    default: fail("unknown command “\(command)”\n\n\(usage)")
    }
} catch {
    fail(error.localizedDescription)
}

final class LockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ new: T) { lock.withLock { value = new } }
}

final class TestClipboard: ClipboardProvider, @unchecked Sendable {
    private let box = LockedBox<String?>(nil)
    func text() -> String? { box.get() }
    func setText(_ text: String) { box.set(text); print("clipboard: guest sent “\(text)”") }
}
