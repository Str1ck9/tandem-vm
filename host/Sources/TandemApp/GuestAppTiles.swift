import AppKit
import VMCore

/// Keeps one stand-in app in the Dock for every guest program that has windows in Seamless Mode
/// (see `GuestAppBundle`). Tandem remains the owner of the windows: the tiles give each program its
/// own icon, name and place in the Dock and in Command-Tab, and choosing one brings its window forward.
@MainActor
final class GuestAppTiles {
    struct Program: Equatable {
        /// What the tile stands for: "app:<file name>" or "program:<id>".
        var key: String
        var name: String
    }

    private struct Tile {
        var program: Program
        var firstSeen: Date
        /// Nil until the stand-in has been written and started.
        var bundleID: String?
    }

    private let vm: UUID
    private let directory: URL
    private var tiles: [String: Tile] = [:]
    /// A program seen without an icon waits this long for the guest to hand one out.
    private let iconGrace: TimeInterval = 2.5

    /// Off when the user turned the tiles off in Preferences, or this build has no stand-in program.
    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: "guestAppDockTiles") as? Bool ?? true) && stub != nil
    }

    /// The stand-in's program file: inside Tandem.app, or next to the executable in a development build.
    static let stub: URL? = {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent(GuestAppBundle.executableName),
                          Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(GuestAppBundle.executableName)]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    init(vm: UUID, vmName: String) {
        self.vm = vm
        // In the library this copy of Tandem works on, so a test library keeps its tiles to itself.
        self.directory = GuestAppBundle.directory(root: MacApps.libraryRoot ?? VMLibrary.defaultRoot(), vmName: vmName)
    }

    /// This VM's own setting, which wins over the app-wide preference. Nil follows the preference.
    var override: Bool?

    /// Call with the programs that have windows now. Starts tiles for new ones and ends the others'.
    func update(_ programs: [Program], icon: (Program) -> CGImage?) {
        guard override ?? Self.isEnabled, Self.stub != nil else { stop(); return }
        let wanted = Set(programs.map(\.key))
        for (key, tile) in tiles where !wanted.contains(key) {
            quit(tile)
            tiles[key] = nil
        }
        for program in programs {
            var tile = tiles[program.key] ?? Tile(program: program, firstSeen: Date(), bundleID: nil)
            if tile.bundleID == nil {
                let picture = icon(program)
                // The Dock keeps the icon a tile started with, so wait a moment for the real one.
                if picture != nil || launcher?(program) != nil || Date().timeIntervalSince(tile.firstSeen) > iconGrace {
                    tile.bundleID = start(program, icon: picture)
                }
            }
            tiles[program.key] = tile
        }
    }

    /// True while a program is waiting for its icon; the owner should call `update` again shortly.
    var hasPending: Bool { tiles.values.contains { $0.bundleID == nil } }

    func stop() {
        for tile in tiles.values { quit(tile) }
        tiles = [:]
    }

    /// The launcher the user keeps for a program, if any: it then serves as the program's tile.
    var launcher: ((Program) -> URL?)?

    /// Signs a bundle put together by hand as a whole, so the system accepts it as an app.
    static func sign(_ bundle: URL) {
        _ = try? ToolRun.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", bundle.path],
                             timeout: ToolRun.Limit.quick, output: .discard, errors: .discard)
    }

    private func start(_ program: Program, icon: CGImage?) -> String? {
        guard let stub = Self.stub else { return nil }
        do {
            let bundle: URL
            if let kept = launcher?(program), FileManager.default.fileExists(atPath: kept.path) {
                bundle = kept
            } else {
                bundle = try GuestAppBundle.write(in: directory, name: program.name, vm: vm, program: program.key, icon: icon, stub: stub)
                Self.sign(bundle)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            configuration.arguments = [String(ProcessInfo.processInfo.processIdentifier)]
            NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, _ in }
            return GuestAppBundle.bundleIdentifier(vm: vm, program: program.key)
        } catch {
            return nil
        }
    }

    private func quit(_ tile: Tile) {
        guard let bundleID = tile.bundleID else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(GuestAppBundle.quitNotification), object: bundleID, userInfo: nil, deliverImmediately: true)
        // In case it was still starting when the notification went out.
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { app.terminate() }
    }
}
