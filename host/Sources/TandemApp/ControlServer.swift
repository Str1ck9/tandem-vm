import Foundation
import TandemControl

/// Listens on the library's `control.sock` and answers the `tandem` command and its MCP server.
///
/// The serving itself (one thread per connection, owner-only socket, same-user peers, a connection
/// budget and an idle deadline) is `ControlSocketServer`; requests are answered on the main actor by
/// `ControlService`, the only place that decides what a client may do.
final class ControlServer: @unchecked Sendable {
    private let server: ControlSocketServer
    private(set) var startError: String?

    init(libraryRoot: URL, handle: @escaping @Sendable (ControlRequest) async -> ControlResponse) {
        server = ControlSocketServer(path: ControlProtocol.socketURL(libraryRoot: libraryRoot).path, handle: handle)
    }

    func start() {
        do { try server.start() }
        catch { startError = "\(error)"; NSLog("Tandem control socket: \(error)") }
    }

    func stop() { server.stop() }
}
