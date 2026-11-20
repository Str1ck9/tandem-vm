import Foundation

/// Settings of the control API, kept in `control.json` in the library folder (not in the app's
/// preferences), so a test library and the real one never share them and the MCP server can read them
/// without starting the app.
public struct ControlSettings: Codable, Equatable, Sendable {
    /// "Allow AI tools (MCP) to control Tandem". Off until the user turns it on.
    public var allowAITools: Bool

    public init(allowAITools: Bool = false) { self.allowAITools = allowAITools }

    public static func url(libraryRoot: URL) -> URL { libraryRoot.appendingPathComponent(ControlProtocol.settingsName) }

    public static func load(libraryRoot: URL) -> ControlSettings {
        guard let data = try? Data(contentsOf: url(libraryRoot: libraryRoot)),
              let settings = try? JSONDecoder().decode(ControlSettings.self, from: data) else { return ControlSettings() }
        return settings
    }

    public func save(libraryRoot: URL) throws {
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(libraryRoot: libraryRoot), options: .atomic)
    }
}

/// What a client may do, before any VM is looked at. VM-specific rules (commands, sharing) are the
/// sharing policy's; this is the global gate.
public enum ControlGate {
    public static let aiOffMessage = "AI tools are not allowed to control Tandem."
    public static let aiOffDetail = "Turn on “Allow AI tools (MCP) to control Tandem” in Tandem > Settings > Advanced."

    /// Throws for a request the app must not even look at.
    public static func check(_ request: ControlRequest, settings: ControlSettings) throws {
        guard request.v == ControlProtocol.version else {
            throw ControlError("bad-request", "This version of the control protocol (\(request.v)) is not supported; Tandem speaks version \(ControlProtocol.version).")
        }
        guard let op = request.operation else { throw ControlError("unknown-op", "Unknown operation “\(request.op)”.") }
        if request.client == .mcp && !settings.allowAITools { throw ControlError.refused(aiOffMessage, detail: aiOffDetail) }
        if op.needsVM && (request.vm ?? "").isEmpty { throw ControlError("bad-request", "Name a virtual machine for “\(op.rawValue)”.") }
    }
}
