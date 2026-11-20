import AppKit
import Foundation
import TandemControl
import VMCore

/// The control API's place in the app: started once with the first window, stopped at quit.
@MainActor
enum ControlAPI {
    private static var server: ControlServer?
    private static var service: ControlService?

    static var libraryRoot: URL { ControlProtocol.libraryRoot() }
    static var startError: String? { server?.startError }

    static func start(_ model: AppModel) {
        guard server == nil else { return }
        let service = ControlService(model: model, libraryRoot: libraryRoot)
        let server = ControlServer(libraryRoot: libraryRoot) { request in await service.handle(request) }
        server.start()
        self.service = service
        self.server = server
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ControlAPI.server?.stop() }
        }
    }

    // MARK: The command-line tool

    /// The `tandem` program inside this app.
    static var bundledTool: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent(ControlLauncher.toolPathInApp)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Where the tool is linked: Homebrew's bin folder when this user can write to it (it is on PATH for
    /// Homebrew users), otherwise `~/.local/bin`. Neither needs an administrator password.
    static var installFolder: URL {
        let homebrew = URL(fileURLWithPath: "/opt/homebrew/bin")
        if FileManager.default.isWritableFile(atPath: homebrew.path) { return homebrew }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
    }

    static var installedLink: URL { installFolder.appendingPathComponent("tandem") }

    /// Where the installed link points, if there is one.
    static var installedTarget: String? { try? FileManager.default.destinationOfSymbolicLink(atPath: installedLink.path) }

    /// Links `tandem` into `installFolder`. Replaces an older link of ours; refuses to replace anything else.
    static func installTool() throws -> URL {
        guard let tool = bundledTool else {
            throw VMError("This copy of Tandem does not contain the command-line tool.", detail: "Build it with scripts/build-app.sh.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: installFolder, withIntermediateDirectories: true)
        let link = installedLink
        if let attributes = try? fm.attributesOfItem(atPath: link.path) {
            guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
                throw VMError("\(link.path) already exists and is not Tandem’s.", detail: "Remove it first if you want Tandem’s tool there.")
            }
            try fm.removeItem(at: link)
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: tool)
        return link
    }

    /// True when `folder` is on the PATH a login shell gets.
    static func folderIsOnPath(_ folder: URL) -> Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").contains { URL(fileURLWithPath: String($0)).standardizedFileURL == folder.standardizedFileURL }
    }
}
