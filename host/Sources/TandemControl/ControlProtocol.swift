import Foundation

/// Tandem's local control protocol (version 1).
///
/// The app listens on a unix socket, `control.sock` in the library folder (owner-only permissions; the
/// server also checks the peer's user id). Each request and each response is one JSON object on one line:
///
///     → {"v":1,"id":7,"client":"cli","op":"start","vm":"Debian","args":{"wait":true}}
///     ← {"v":1,"id":7,"ok":true,"result":{...}}
///     ← {"v":1,"id":7,"ok":false,"error":{"code":"refused","message":"…","detail":"…"}}
///
/// `client` says who asks: `cli` (the `tandem` command, run by the Mac's user) or `mcp` (an AI tool through
/// `tandem mcp`). The app decides what each may do; the client only says who it is.
public enum ControlProtocol {
    public static let version = 1
    public static let socketName = "control.sock"
    public static let settingsName = "control.json"

    /// The library folder: `TANDEM_HOME`, or `~/Library/Application Support/Tandem`.
    public static func libraryRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = environment["TANDEM_HOME"], !home.isEmpty { return URL(fileURLWithPath: home, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tandem", isDirectory: true)
    }

    public static func socketURL(libraryRoot: URL) -> URL { libraryRoot.appendingPathComponent(socketName) }
}

public enum ControlClient: String, Codable, Sendable {
    case cli, mcp
}

/// Every operation the app answers. Requests name them by raw value.
public enum ControlOp: String, CaseIterable, Sendable {
    case status, list, info, ip
    case start, stop, suspend, resume, pause, restart, reset
    case snapshotList = "snapshot.list", snapshotTake = "snapshot.take", snapshotRevert = "snapshot.revert", snapshotDelete = "snapshot.delete"
    /// Marks (or unmarks) the snapshot AI tools may revert to. The person's decision; never an AI tool's.
    case snapshotBaseline = "snapshot.baseline"
    case screenshot
    case sharing, share, unshare
    case services
    case keepAwake = "keep-awake"
    case programs, launch
    case exec
    case clone

    /// Operations that need a VM named in the request.
    public var needsVM: Bool { ![.status, .list].contains(self) }

    /// Operations that change something (as opposed to reading).
    public var changes: Bool {
        switch self {
        case .status, .list, .info, .ip, .snapshotList, .screenshot, .sharing, .services, .programs: return false
        default: return true
        }
    }
}

public struct ControlRequest: Codable, Equatable, Sendable {
    public var v: Int
    public var id: Int
    public var client: ControlClient
    public var op: String
    public var vm: String?
    public var args: [String: JSON]

    public init(id: Int, client: ControlClient, op: ControlOp, vm: String? = nil, args: [String: JSON] = [:]) {
        self.v = ControlProtocol.version; self.id = id; self.client = client; self.op = op.rawValue; self.vm = vm; self.args = args
    }

    private enum CodingKeys: String, CodingKey { case v, id, client, op, vm, args }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        id = try c.decode(Int.self, forKey: .id)
        client = try c.decode(ControlClient.self, forKey: .client)
        op = try c.decode(String.self, forKey: .op)
        vm = try c.decodeIfPresent(String.self, forKey: .vm)
        args = try c.decodeIfPresent([String: JSON].self, forKey: .args) ?? [:]
    }

    public var operation: ControlOp? { ControlOp(rawValue: op) }
    public func string(_ key: String) -> String? { args[key]?.string }
    public func bool(_ key: String) -> Bool? { args[key]?.bool }
    public func int(_ key: String) -> Int? { args[key]?.int }
}

public struct ControlError: Codable, Equatable, Error, Sendable, CustomStringConvertible {
    /// `bad-request`, `unknown-op`, `no-such-vm`, `refused` (a permission says no), `failed`, `timeout`, `unavailable`.
    public var code: String
    public var message: String
    public var detail: String?

    public init(_ code: String, _ message: String, detail: String? = nil) {
        self.code = code; self.message = message; self.detail = detail
    }
    public var description: String { detail.map { "\(message)\n\($0)" } ?? message }

    public static func refused(_ message: String, detail: String? = nil) -> ControlError { ControlError("refused", message, detail: detail) }
    public static func failed(_ message: String, detail: String? = nil) -> ControlError { ControlError("failed", message, detail: detail) }
}

public struct ControlResponse: Codable, Equatable, Sendable {
    public var v: Int
    public var id: Int
    public var ok: Bool
    public var result: JSON?
    public var error: ControlError?

    public static func success(_ id: Int, _ result: JSON = .object([:])) -> ControlResponse {
        ControlResponse(v: ControlProtocol.version, id: id, ok: true, result: result, error: nil)
    }
    public static func failure(_ id: Int, _ error: ControlError) -> ControlResponse {
        ControlResponse(v: ControlProtocol.version, id: id, ok: false, result: nil, error: error)
    }
}

// MARK: Line framing

public enum ControlCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }
}
