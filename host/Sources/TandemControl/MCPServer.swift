import Foundation

/// `tandem mcp`: Tandem as a Model Context Protocol server over stdin/stdout (JSON-RPC 2.0, one message
/// per line). Every tool is one control request with `client: mcp`, so the app applies its rules: nothing
/// at all while "Allow AI tools (MCP) to control Tandem" is off, and per VM the AI level (`AITier`:
/// off, observe, operate, full) and the sharing policy (commands from AI tools are off unless turned on
/// for that VM; restricted VMs get no folders).
public final class MCPServer {
    public typealias Transport = (ControlOp, String?, [String: JSON]) throws -> JSON

    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    private let transport: Transport
    private let aiAllowed: () -> Bool
    private let version: String

    /// `transport` sends a control request and returns its result (or throws its `ControlError`).
    /// `aiAllowed` reads the library's switch, so a refused call does not even start the app.
    public init(version: String = "1", aiAllowed: @escaping () -> Bool, transport: @escaping Transport) {
        self.version = version; self.aiAllowed = aiAllowed; self.transport = transport
    }

    // MARK: Tools

    struct Tool {
        var name: String
        var description: String
        var properties: [String: JSON]
        var required: [String]
        var readOnly: Bool
        var destructive: Bool
    }

    private static func prop(_ type: String, _ description: String) -> JSON {
        .object(["type": .string(type), "description": .string(description)])
    }
    private static let vmProp = prop("string", "The virtual machine's name, or the start of its id (see list_vms).")

    static let tools: [Tool] = [
        Tool(name: "list_vms", description: "List Tandem's virtual machines with their state, operating system and IP address.",
             properties: [:], required: [], readOnly: true, destructive: false),
        Tool(name: "vm_info", description: "Details of one virtual machine: hardware, guest tools, guest addresses, sharing and snapshots.",
             properties: ["vm": vmProp], required: ["vm"], readOnly: true, destructive: false),
        Tool(name: "start_vm", description: "Start a virtual machine, or resume it if it is suspended or paused. Waits until it runs.",
             properties: ["vm": vmProp, "wait_for_tools": prop("boolean", "Also wait until the guest tools are connected (needed before guest_exec).")],
             required: ["vm"], readOnly: false, destructive: false),
        Tool(name: "stop_vm", description: "Shut a virtual machine down. With force it is powered off at once and unsaved work in the guest is lost.",
             properties: ["vm": vmProp, "force": prop("boolean", "Power off instead of asking the guest to shut down.")],
             required: ["vm"], readOnly: false, destructive: true),
        Tool(name: "suspend_vm", description: "Save a running virtual machine's memory to disk and stop it; starting it again continues where it was.",
             properties: ["vm": vmProp], required: ["vm"], readOnly: false, destructive: false),
        Tool(name: "resume_vm", description: "Resume a suspended or paused virtual machine.",
             properties: ["vm": vmProp], required: ["vm"], readOnly: false, destructive: false),
        Tool(name: "list_snapshots", description: "List a virtual machine's snapshots.",
             properties: ["vm": vmProp], required: ["vm"], readOnly: true, destructive: false),
        Tool(name: "clone_vm", description: "Make an instant copy of a stopped virtual machine (APFS clone; shares disk space until either changes). The copy is a new machine (new firmware ID, TPM, network address; its guest gets a new host or computer name at first start) unless keep_identity is set.",
             properties: ["vm": vmProp, "name": prop("string", "Name for the copy (default: \"<name> Copy\")."),
                          "keep_identity": prop("boolean", "Keep the firmware ID and TPM, so Windows stays activated. The two VMs must then not run at the same time."),
                          "include_snapshots": prop("boolean", "Copy the snapshots too.")],
             required: ["vm"], readOnly: false, destructive: false),
        Tool(name: "take_snapshot", description: "Take a snapshot of a virtual machine (of a running one, its memory too).",
             properties: ["vm": vmProp, "name": prop("string", "Name for the snapshot."), "note": prop("string", "Optional description.")],
             required: ["vm"], readOnly: false, destructive: false),
        Tool(name: "revert_snapshot", description: "DESTRUCTIVE: put a virtual machine back to a snapshot. Everything since that snapshot that was not saved in another snapshot is lost. A running VM is stopped and started again.",
             properties: ["vm": vmProp, "snapshot": prop("string", "The snapshot's name or the start of its id (see list_snapshots).")],
             required: ["vm", "snapshot"], readOnly: false, destructive: true),
        Tool(name: "screenshot", description: "A picture of a running virtual machine's screen (QEMU engine VMs, such as Windows and Linux).",
             properties: ["vm": vmProp], required: ["vm"], readOnly: true, destructive: false),
        Tool(name: "guest_exec", description: "Run a command in the guest's shell (cmd on Windows, sh on Linux) and return its output and exit code. Only for VMs whose sharing settings allow commands from AI tools; the VM must be running with its guest tools connected.",
             properties: ["vm": vmProp, "command": prop("string", "One command line for the guest's shell."),
                          "user": prop("string", "Linux: run as this user instead of root."),
                          "elevated": prop("boolean", "Windows: run with administrator rights instead of as the signed-in user."),
                          "timeout_seconds": prop("integer", "Stop waiting after this many seconds (default 60, at most 3600).")],
             required: ["vm", "command"], readOnly: false, destructive: true),
        Tool(name: "share_folder", description: "Share a Mac folder with a virtual machine (refused for restricted VMs). Windows sees it on drive Z:, Linux under /media/mac.",
             properties: ["vm": vmProp, "path": prop("string", "Absolute path of the Mac folder."),
                          "read_only": prop("boolean", "The guest may read but not change the folder. Default true; set false only when the guest must write to the Mac folder."),
                          "temporary": prop("boolean", "Share only until the VM shuts down (the VM must be running).")],
             required: ["vm", "path"], readOnly: false, destructive: false),
        Tool(name: "unshare_folder", description: "Stop sharing a folder with a virtual machine.",
             properties: ["vm": vmProp, "folder": prop("string", "The shared folder's name or Mac path (see vm_info or list_vms).")],
             required: ["vm", "folder"], readOnly: false, destructive: false),
    ]

    /// What each tool needs, stated in its description so an agent knows before it asks. The app enforces
    /// it (`AIAuthorization`); this is only the explanation. Levels are set per VM by the person at the Mac.
    static let levelNotes: [String: String] = [
        "list_vms": "",
        "vm_info": AIAuthorization.levelNote(for: .info),
        "list_snapshots": AIAuthorization.levelNote(for: .snapshotList),
        "screenshot": AIAuthorization.levelNote(for: .screenshot),
        "start_vm": AIAuthorization.levelNote(for: .start),
        "suspend_vm": AIAuthorization.levelNote(for: .suspend),
        "resume_vm": AIAuthorization.levelNote(for: .resume),
        "take_snapshot": AIAuthorization.levelNote(for: .snapshotTake),
        "unshare_folder": AIAuthorization.levelNote(for: .unshare),
        "stop_vm": "Needs the AI level Operate; with force it needs Full.",
        "guest_exec": "Needs the AI level Operate or higher, and the VM's “Commands from the Mac” must allow AI tools.",
        "share_folder": "Needs the AI level Operate for a read-only share; sharing a folder the guest can change needs Full.",
        "clone_vm": AIAuthorization.levelNote(for: .clone),
        "revert_snapshot": AIAuthorization.levelNote(for: .snapshotRevert)
            + " If the VM has a baseline snapshot, only that snapshot can be reverted to.",
    ]

    static func toolJSON(_ tool: Tool) -> JSON {
        let note = levelNotes[tool.name] ?? ""
        let description = note.isEmpty ? tool.description : tool.description + " " + note
        return .object([
            "name": .string(tool.name), "description": .string(description),
            "inputSchema": .object(["type": "object", "properties": .object(tool.properties), "required": .array(tool.required.map(JSON.string))]),
            "annotations": .object(["readOnlyHint": JSON(tool.readOnly), "destructiveHint": JSON(tool.destructive)]),
        ])
    }

    // MARK: JSON-RPC

    /// Handles one incoming line. Returns the line to send back, or nil for a notification.
    public func handle(line: Data) -> Data? {
        guard let message = try? JSON.decode(line), case .object(let o) = message else {
            return reply(.null, error: (-32700, "Parse error"))
        }
        let id = o["id"] ?? .null
        guard let method = o["method"]?.string else {
            // A response to something we never asked, or garbage: ignore responses, refuse the rest.
            return o["result"] != nil || o["error"] != nil ? nil : reply(id, error: (-32600, "Invalid request"))
        }
        let isNotification = o["id"] == nil
        let params = o["params"]?.object ?? [:]
        switch method {
        case "initialize":
            let wanted = params["protocolVersion"]?.string ?? Self.supportedVersions[0]
            let chosen = Self.supportedVersions.contains(wanted) ? wanted : Self.supportedVersions[0]
            return reply(id, result: .object([
                "protocolVersion": .string(chosen),
                "capabilities": .object(["tools": .object(["listChanged": false])]),
                "serverInfo": .object(["name": "tandem", "version": .string(version)]),
                "instructions": .string("Controls the virtual machines of Tandem on this Mac. The user must turn on “Allow AI tools (MCP) to control Tandem” in Tandem's settings. Each VM has an AI level (Off, Observe, Operate, Full) that decides which tools work on it; a tool's description says what it needs, and guest_exec also needs the VM's “Commands from the Mac” to allow AI tools. Revert and clone need Full, and deleting snapshots is not offered."),
            ]))
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            return reply(id, result: .object([:]))
        case "tools/list":
            return reply(id, result: .object(["tools": .array(Self.tools.map(Self.toolJSON))]))
        case "tools/call":
            guard let name = params["name"]?.string, let tool = Self.tools.first(where: { $0.name == name }) else {
                return reply(id, error: (-32602, "Unknown tool \(params["name"]?.string ?? "")"))
            }
            return reply(id, result: call(tool, arguments: params["arguments"]?.object ?? [:]))
        default:
            return isNotification ? nil : reply(id, error: (-32601, "Method not found: \(method)"))
        }
    }

    private func reply(_ id: JSON, result: JSON) -> Data {
        var line = JSON.object(["jsonrpc": "2.0", "id": id, "result": result]).encodedLine()
        line.append(0x0A)
        return line
    }

    private func reply(_ id: JSON, error: (Int, String)) -> Data {
        var line = JSON.object(["jsonrpc": "2.0", "id": id, "error": .object(["code": JSON(error.0), "message": .string(error.1)])]).encodedLine()
        line.append(0x0A)
        return line
    }

    // MARK: Tool calls

    private static func text(_ s: String, error: Bool = false) -> JSON {
        .object(["content": .array([.object(["type": "text", "text": .string(s)])]), "isError": JSON(error)])
    }

    func call(_ tool: Tool, arguments a: [String: JSON]) -> JSON {
        guard aiAllowed() else { return Self.text("\(ControlGate.aiOffMessage) \(ControlGate.aiOffDetail)", error: true) }
        for key in tool.required where (a[key]?.string ?? "").isEmpty {
            return Self.text("Missing argument “\(key)”.", error: true)
        }
        let vm = a["vm"]?.string
        do {
            switch tool.name {
            case "list_vms": return Self.text(try transport(.list, nil, [:]).pretty())
            case "vm_info": return Self.text(try transport(.info, vm, [:]).pretty())
            case "start_vm":
                return Self.text(try transport(.start, vm, ["wait": true, "waitForTools": JSON(a["wait_for_tools"]?.bool ?? false)]).pretty())
            case "stop_vm": return Self.text(try transport(.stop, vm, ["force": JSON(a["force"]?.bool ?? false), "wait": true]).pretty())
            case "suspend_vm": return Self.text(try transport(.suspend, vm, [:]).pretty())
            case "resume_vm": return Self.text(try transport(.resume, vm, [:]).pretty())
            case "list_snapshots": return Self.text(try transport(.snapshotList, vm, [:]).pretty())
            case "clone_vm":
                var args: [String: JSON] = [:]
                if let name = a["name"]?.string { args["name"] = .string(name) }
                if a["keep_identity"]?.bool == true { args["keepIdentity"] = true }
                if a["include_snapshots"]?.bool == true { args["includeSnapshots"] = true }
                return Self.text(try transport(.clone, vm, args).pretty())
            case "take_snapshot":
                var args: [String: JSON] = [:]
                if let name = a["name"]?.string { args["name"] = .string(name) }
                if let note = a["note"]?.string { args["note"] = .string(note) }
                return Self.text(try transport(.snapshotTake, vm, args).pretty())
            case "revert_snapshot": return Self.text(try transport(.snapshotRevert, vm, ["snapshot": a["snapshot"] ?? .null]).pretty())
            case "screenshot":
                let shot = try transport(.screenshot, vm, ["maxWidth": 1600])
                guard let png = shot["png"]?.string else { return Self.text("No picture came back.", error: true) }
                return .object(["content": .array([.object(["type": "image", "data": .string(png), "mimeType": "image/png"])]), "isError": false])
            case "guest_exec":
                var args: [String: JSON] = ["command": a["command"] ?? .null, "elevated": JSON(a["elevated"]?.bool ?? false)]
                if let user = a["user"]?.string { args["user"] = .string(user) }
                if let timeout = a["timeout_seconds"]?.int { args["timeout"] = JSON(timeout) }
                let result = try transport(.exec, vm, args)
                let completed = result["status"]?.string == "completed"
                var text = "exit code: \(result["exitCode"]?.int ?? -1)"
                if !completed { text = "status: \(result["status"]?.string ?? "?") — \(result["message"]?.string ?? "")" }
                if let out = result["stdout"]?.string, !out.isEmpty { text += "\n--- stdout ---\n" + out }
                if let err = result["stderr"]?.string, !err.isEmpty { text += "\n--- stderr ---\n" + err }
                if result["stdoutTruncated"]?.bool == true || result["stderrTruncated"]?.bool == true { text += "\n(output was cut short)" }
                return Self.text(text, error: !completed)
            case "share_folder":
                return Self.text(try transport(.share, vm, ["path": a["path"] ?? .null, "readOnly": JSON(a["read_only"]?.bool ?? true),
                                                             "temporary": JSON(a["temporary"]?.bool ?? false)]).pretty())
            case "unshare_folder": return Self.text(try transport(.unshare, vm, ["folder": a["folder"] ?? .null]).pretty())
            default: return Self.text("Unknown tool.", error: true)
            }
        } catch let error as ControlError {
            return Self.text(error.description, error: true)
        } catch {
            return Self.text(error.localizedDescription, error: true)
        }
    }

    // MARK: Loop

    /// Reads messages from stdin until it closes, answering each on stdout.
    public func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { return }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) else { continue }
                if let answer = handle(line: line) { output.write(answer) }
            }
        }
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}
