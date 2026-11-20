import AppKit
import CoreServices
import GuestLink
import VMCore

/// Launchers: small Mac apps, one per Windows program the user chose, kept where the Mac looks for
/// apps. They can be pinned to the Dock, found with Spotlight and chosen under Finder's Open With.
/// Opening one starts or resumes its VM and opens the program (see `LaunchPipeline.swift`).
@MainActor
enum MacApps {
    /// `~/Applications/Tandem`, one folder per VM inside. A test library keeps its launchers to itself.
    static var root: URL {
        let env = ProcessInfo.processInfo.environment
        if let path = env["TANDEM_MAC_APPS"] { return URL(fileURLWithPath: path, isDirectory: true) }
        if let home = env["TANDEM_HOME"] { return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Mac Applications", isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Tandem", isDirectory: true)
    }

    /// The VM library a launcher must name so that the Tandem it starts opens the same one. Nil for the default.
    static var libraryRoot: URL? {
        ProcessInfo.processInfo.environment["TANDEM_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Tandem.app as launchers should start it. A development build run outside a bundle has none.
    static var host: URL? {
        let bundle = Bundle.main.bundleURL
        return bundle.pathExtension == "app" ? bundle : nil
    }

    static func directory(vmName: String) -> URL {
        root.appendingPathComponent(GuestAppBundle.fileName(vmName), isDirectory: true)
    }

    /// The launchers on disk for one VM, by program id. Found by what they say they are, not by folder,
    /// so a renamed VM keeps its launchers.
    static func installed(for vm: UUID) -> (launchers: [String: URL], programFiles: [String: String]) {
        let fm = FileManager.default
        var found: [String: URL] = [:]
        // The file name of each launcher's program in the guest, lower case, to its program id.
        var files: [String: String] = [:]
        for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for app in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where app.pathExtension == "app" {
                guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
                      info[GuestAppBundle.launcherKey] as? Bool == true,
                      (info[GuestAppBundle.vmKey] as? String).flatMap(UUID.init(uuidString:)) == vm,
                      let key = info[GuestAppBundle.programKey] as? String, key.hasPrefix("program:") else { continue }
                let programID = String(key.dropFirst("program:".count))
                found[programID] = app
                if let target = info[GuestAppBundle.targetKey] as? String,
                   let file = target.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last, !file.isEmpty {
                    files[file.lowercased()] = programID
                }
            }
        }
        return (found, files)
    }

    /// Writes a launcher and tells the system about it, so Open With and Spotlight know it at once.
    static func add(program: GuestProgram, info: GuestProgramInfo?, icon: CGImage?, vm: UUID, vmName: String) throws -> URL {
        guard let stub = GuestAppTiles.stub, let host else {
            throw VMError("This copy of Tandem cannot make launchers.", detail: "It was not started from Tandem.app.")
        }
        let directory = directory(vmName: vmName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let launcher = GuestAppBundle.Launcher(host: host, library: libraryRoot, documentExtensions: info?.extensions ?? [], target: info?.target)
        let bundle = try GuestAppBundle.write(in: directory, name: program.name, vm: vm, program: "program:" + program.id,
                                              icon: icon, stub: stub, launcher: launcher)
        GuestAppTiles.sign(bundle)
        LSRegisterURL(bundle as CFURL, true)
        return bundle
    }

    /// A launcher carries its own copy of the stand-in program. After Tandem has been updated, the copies
    /// are brought up to date, so every launcher behaves like the Tandem that will answer it.
    static func updateStandIns(in launchers: [URL]) {
        guard let stub = GuestAppTiles.stub, let current = try? Data(contentsOf: stub) else { return }
        for bundle in launchers {
            let copy = bundle.appendingPathComponent("Contents/MacOS").appendingPathComponent(GuestAppBundle.executableName)
            guard let existing = try? Data(contentsOf: copy) else { continue }
            if existing != current {
                guard (try? current.write(to: copy, options: .atomic)) != nil else { continue }
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
            } else { continue }
            GuestAppTiles.sign(bundle)
        }
    }

    static func remove(_ bundle: URL) {
        // Forget it first, so Open With stops offering a launcher that is gone.
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        if FileManager.default.isExecutableFile(atPath: lsregister) {
            _ = try? ToolRun.run(URL(fileURLWithPath: lsregister), ["-u", bundle.path],
                                 timeout: ToolRun.Limit.quick, output: .discard, errors: .discard)
        }
        try? FileManager.default.removeItem(at: bundle)
        // Leave no empty VM folder behind.
        let folder = bundle.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter({ $0 != ".DS_Store" }).isEmpty == true {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

extension VMSession {
    func refreshMacLaunchers() {
        let installed = MacApps.installed(for: id)
        // Once per run of Tandem and VM: launchers made by an older Tandem get this one's stand-in.
        if !launches.standInsChecked {
            launches.standInsChecked = true
            MacApps.updateStandIns(in: Array(installed.launchers.values))
        }
        macLauncherFiles = installed.programFiles
        macLaunchers = installed.launchers
    }

    /// Makes a launcher for a program of this (running) VM: asks the guest which files the program
    /// opens and for a large icon, then writes the app.
    @discardableResult
    func addToMac(_ program: GuestProgram) async throws -> URL {
        guard state == .running, let agent else { throw VMError("Start “\(config.name)” first.", detail: "Its guest tools say which files the program opens.") }
        var info: GuestProgramInfo?
        var icon = guestIcons["program:" + program.id]
        if agent.capabilities & 256 != 0 {
            link.requestProgramInfo(id: program.id)
            let answer = await launches.waitForProgramInfo(id: program.id, timeout: 40)
            info = answer?.info
            // A store app's own picture file is the best icon there is.
            if let logo = answer?.logo, !logo.isEmpty, let image = NSImage(data: logo)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                icon = image
            } else if (icon?.width ?? 0) < 128 {
                // The program file is known to the guest now, so it can hand out a large icon.
                link.requestIcon(.program(program.id), size: 256, first: true)
                for _ in 0..<80 {
                    if let large = guestIcons["program:" + program.id], large.width >= 128 { icon = large; break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
        let bundle = try MacApps.add(program: program, info: info, icon: icon, vm: id, vmName: config.name)
        refreshMacLaunchers()
        updateTiles()
        return bundle
    }

    func removeFromMac(programID: String) {
        guard let bundle = macLaunchers[programID] else { return }
        // A running launcher is told to go; its file is about to.
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(GuestAppBundle.quitNotification), object: GuestAppBundle.bundleIdentifier(vm: id, program: "program:" + programID),
            userInfo: nil, deliverImmediately: true)
        MacApps.remove(bundle)
        refreshMacLaunchers()
        updateTiles()
    }

    /// When the VM is deleted its launchers have nothing left to open.
    func removeAllFromMac() {
        for programID in macLaunchers.keys { removeFromMac(programID: programID) }
    }
}
