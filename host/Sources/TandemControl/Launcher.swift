import Foundation
import IdentityCore

/// Finds the running app for a library, or starts it hidden and waits for its control socket.
public enum ControlLauncher {
    public static var bundleIdentifier: String { TandemIdentity.app }

    /// Where the tool sits inside the app. (Not `Contents/MacOS`: on a case-insensitive disk `tandem` and
    /// the app's own `Tandem` would be the same file.)
    public static let toolPathInApp = "Contents/Helpers/tandem"

    /// The Tandem.app this tool belongs to: the app around the running program (the tool is installed as
    /// `Tandem.app/Contents/Helpers/tandem` and linked onto PATH), or `TANDEM_APP`. Nil: ask Launch Services.
    public static func appURL(executable: URL? = Bundle.main.executableURL,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let explicit = environment["TANDEM_APP"], !explicit.isEmpty { return URL(fileURLWithPath: explicit) }
        guard let executable else { return nil }
        let real = executable.resolvingSymlinksInPath()
        let folder = real.deletingLastPathComponent()
        let contents = folder.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard ["Helpers", "MacOS"].contains(folder.lastPathComponent), contents.lastPathComponent == "Contents", app.pathExtension == "app" else { return nil }
        return app
    }

    /// Connects to the app serving `libraryRoot`. When none is running and `launch` is true, starts the app
    /// in the background without showing a window and waits up to `timeout` seconds for it to answer.
    public static func connect(libraryRoot: URL, client: ControlClient, launch: Bool = true, timeout: TimeInterval = 30) throws -> ControlConnection {
        if let connection = ControlConnection.open(libraryRoot: libraryRoot, client: client) { return connection }
        guard launch else {
            throw ControlError("unavailable", "Tandem is not running.", detail: "Open Tandem, or run this command without --no-launch.")
        }
        try startApp(libraryRoot: libraryRoot)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let connection = ControlConnection.open(libraryRoot: libraryRoot, client: client) { return connection }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw ControlError("unavailable", "Tandem did not start within \(Int(timeout)) seconds.")
    }

    static func startApp(libraryRoot: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -g: do not bring it to the front; -j: launch hidden. A test library travels with the app.
        var arguments = ["-g", "-j"]
        if let home = ProcessInfo.processInfo.environment["TANDEM_HOME"], !home.isEmpty { arguments += ["--env", "TANDEM_HOME=\(home)"] }
        if let app = appURL() { arguments += ["-a", app.path] } else { arguments += ["-b", bundleIdentifier] }
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Polled, not `waitUntilExit()`, which can miss the exit and wait for good. `open` returns as soon
        // as Launch Services has the app starting; a minute means it is stuck.
        guard waitForExit(process, timeout: 60) else {
            process.terminate()
            throw ControlError("unavailable", "Tandem could not be started.", detail: "`open` did not finish within 60 seconds and was stopped.")
        }
        guard process.terminationStatus == 0 else {
            throw ControlError("unavailable", "Tandem could not be started.", detail: "`open \(arguments.joined(separator: " "))` failed.")
        }
    }

    /// Whether `process` ended within `timeout` seconds (this module does not use VMCore's `ToolRun`).
    static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            // Gone already, but Foundation has not noticed yet: give it a moment to reap.
            if kill(process.processIdentifier, 0) != 0, errno == ESRCH {
                let reaped = Date().addingTimeInterval(2)
                while process.isRunning, Date() < reaped { usleep(5_000) }
                return !process.isRunning
            }
            if Date() >= deadline { return false }
            usleep(20_000)
        }
        return true
    }
}
