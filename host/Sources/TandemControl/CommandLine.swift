import Foundation
import VMCore

/// What a `tandem` command line asks for. Parsing is separate from running so it can be tested.
public enum CLIAction: Equatable {
    case help(topic: String?)
    case version
    case mcp
    case installInfo
    /// One control request. `screenshotFile` is where `screenshot` writes its picture.
    case request(op: ControlOp, vm: String?, args: [String: JSON], screenshotFile: String?)
}

public struct CLIInvocation: Equatable {
    public var json: Bool
    public var launch: Bool
    public var action: CLIAction
}

public enum CLIParser {
    public static let usage = """
    tandem: control Tandem's virtual machines from the command line.

    Usage: tandem [--json] [--no-launch] <command> [arguments]

      status                                   Tandem and its library
      list                                     Virtual machines and their state
      info <vm>                                Settings, guest tools and addresses of one VM
      ip <vm>                                  The guest's IP addresses
      start <vm> [--wait-tools] [--no-wait]    Start (or resume) a VM
      stop <vm> [--force] [--no-wait]          Shut down (--force: power off)
      suspend <vm> | pause <vm>
      resume <vm> [--wait-tools]               Resume a suspended or paused VM
      restart <vm>                             Ask the guest to restart
      reset <vm>                               Restart without asking the guest
      snapshot list <vm>
      clone <vm> [new name] [--keep-identity] [--include-snapshots] [--keep-suspended] [--no-identity-reset]
                                               Copy a stopped VM instantly; a new machine unless --keep-identity
      snapshot take <vm> [name] [--note text]
      snapshot revert <vm> <snapshot>          Throws away the current state
      snapshot delete <vm> <snapshot>
      screenshot <vm> <file.png>
      snapshot baseline <vm> <snapshot|none>   The one snapshot AI tools may revert to (none: no limit)
      sharing <vm> [--commands off|cli|ai] [--ai-tier off|observe|operate|full]
                                               What the VM shares with the Mac; who may run commands
                                               in it (cli: this tool only; ai: also AI tools via MCP);
                                               how much AI tools may do with it (default operate)
      share <vm> <folder> [--read-only] [--temporary] [--name name]
      unshare <vm> <folder name or path>
      services <vm>                            Published guest services
      keep-awake <vm> [on|off]
      programs <vm>                            Windows programs the guest lists
      launch <vm> <program>
      exec <vm> [--user name] [--elevated] [--timeout seconds] -- <command>
                                               Run a command in the guest's shell
      mcp                                      Serve the Model Context Protocol on stdin/stdout
      install-info                             Where this tool and Tandem.app are

    <vm> is a name or the start of an id. --json prints the answer as JSON.
    Tandem is started in the background when it is not running (--no-launch: fail instead).
    """

    public static func parse(_ arguments: [String]) throws -> CLIInvocation {
        var json = false, launch = true
        var rest: [String] = []
        var index = 0
        // Global options come before the command.
        while index < arguments.count, arguments[index].hasPrefix("--"), arguments[index] != "--" {
            switch arguments[index] {
            case "--json": json = true
            case "--no-launch": launch = false
            case "--help": return CLIInvocation(json: json, launch: launch, action: .help(topic: nil))
            case "--version": return CLIInvocation(json: json, launch: launch, action: .version)
            default: throw ControlError("bad-request", "Unknown option \(arguments[index]).")
            }
            index += 1
        }
        rest = Array(arguments[index...])
        guard let command = rest.first else { return CLIInvocation(json: json, launch: launch, action: .help(topic: nil)) }
        var words = Array(rest.dropFirst())
        // `--json` is also accepted after the command.
        if words.contains("--json") { json = true; words.removeAll { $0 == "--json" } }
        let action = try parseCommand(command, &words)
        return CLIInvocation(json: json, launch: launch, action: action)
    }

    private static func parseCommand(_ command: String, _ words: inout [String]) throws -> CLIAction {
        func vm() throws -> String {
            guard let first = words.first, !first.hasPrefix("--") else { throw ControlError("bad-request", "\(command): name a virtual machine.") }
            words.removeFirst()
            return first
        }
        func flag(_ name: String) -> Bool {
            guard let i = words.firstIndex(of: name) else { return false }
            words.remove(at: i); return true
        }
        func option(_ name: String) throws -> String? {
            guard let i = words.firstIndex(of: name) else { return nil }
            guard i + 1 < words.count else { throw ControlError("bad-request", "\(name) needs a value.") }
            let value = words[i + 1]
            words.removeSubrange(i...(i + 1))
            return value
        }
        func done() throws {
            if let extra = words.first { throw ControlError("bad-request", "\(command): unexpected “\(extra)”.") }
        }
        func simple(_ op: ControlOp, args: [String: JSON] = [:]) throws -> CLIAction {
            let name = try vm(); try done()
            return .request(op: op, vm: name, args: args, screenshotFile: nil)
        }

        switch command {
        case "help": return .help(topic: words.first)
        case "version": return .version
        case "mcp": try done(); return .mcp
        case "install-info": try done(); return .installInfo
        case "status": try done(); return .request(op: .status, vm: nil, args: [:], screenshotFile: nil)
        case "list", "ls": try done(); return .request(op: .list, vm: nil, args: [:], screenshotFile: nil)
        case "info": return try simple(.info)
        case "ip": return try simple(.ip)
        case "start":
            let waitTools = flag("--wait-tools"), noWait = flag("--no-wait")
            return try simple(.start, args: ["wait": JSON(!noWait), "waitForTools": JSON(waitTools)])
        case "stop":
            let force = flag("--force"), noWait = flag("--no-wait")
            return try simple(.stop, args: ["force": JSON(force), "wait": JSON(!noWait)])
        case "suspend": return try simple(.suspend)
        case "resume":
            let waitTools = flag("--wait-tools"), noWait = flag("--no-wait")
            return try simple(.resume, args: ["wait": JSON(!noWait), "waitForTools": JSON(waitTools)])
        case "pause": return try simple(.pause)
        case "restart": return try simple(.restart)
        case "reset": return try simple(.reset)
        case "sharing":
            var args: [String: JSON] = [:]
            if let commands = try option("--commands") {
                let map = ["off": "off", "cli": "macUser", "ai": "macUserAndAI"]
                guard let value = map[commands] else { throw ControlError("bad-request", "--commands takes off, cli or ai.") }
                args["commands"] = .string(value)
            }
            if let tier = try option("--ai-tier") {
                guard AITier(rawValue: tier) != nil else { throw ControlError("bad-request", "--ai-tier takes off, observe, operate or full.") }
                args["aiTier"] = .string(tier)
            }
            return try simple(.sharing, args: args)
        case "clone":
            var args: [String: JSON] = [:]
            if flag("--keep-identity") { args["keepIdentity"] = true }
            if flag("--include-snapshots") { args["includeSnapshots"] = true }
            if flag("--keep-suspended") { args["keepSuspended"] = true }
            if flag("--no-identity-reset") { args["resetGuestIdentity"] = false }
            let name = try vm()
            if !words.isEmpty { args["name"] = .string(words.joined(separator: " ")); words.removeAll() }
            return .request(op: .clone, vm: name, args: args, screenshotFile: nil)
        case "services": return try simple(.services)
        case "programs": return try simple(.programs)
        case "snapshot", "snapshots":
            guard let sub = words.first else { throw ControlError("bad-request", "snapshot: say list, take, revert, delete or baseline.") }
            words.removeFirst()
            switch sub {
            case "list", "ls": return try simple(.snapshotList)
            case "take", "create":
                let note = try option("--note")
                let name = try vm()
                let label = words.isEmpty ? nil : words.joined(separator: " ")
                words.removeAll()
                var args: [String: JSON] = [:]
                if let label { args["name"] = .string(label) }
                if let note { args["note"] = .string(note) }
                return .request(op: .snapshotTake, vm: name, args: args, screenshotFile: nil)
            case "revert", "delete", "rm":
                let name = try vm()
                guard !words.isEmpty else { throw ControlError("bad-request", "snapshot \(sub): name the snapshot.") }
                let snapshot = words.joined(separator: " "); words.removeAll()
                return .request(op: sub == "revert" ? .snapshotRevert : .snapshotDelete, vm: name, args: ["snapshot": .string(snapshot)], screenshotFile: nil)
            case "baseline":
                let name = try vm()
                guard !words.isEmpty else { throw ControlError("bad-request", "snapshot baseline: name the snapshot, or say none.") }
                let snapshot = words.joined(separator: " "); words.removeAll()
                return .request(op: .snapshotBaseline, vm: name, args: ["snapshot": .string(snapshot)], screenshotFile: nil)
            default: throw ControlError("bad-request", "snapshot: unknown “\(sub)”; say list, take, revert, delete or baseline.")
            }
        case "screenshot":
            let name = try vm()
            guard let file = words.first else { throw ControlError("bad-request", "screenshot: give the file to write.") }
            words.removeFirst(); try done()
            return .request(op: .screenshot, vm: name, args: [:], screenshotFile: file)
        case "share":
            let readOnly = flag("--read-only"), temporary = flag("--temporary")
            let label = try option("--name")
            let name = try vm()
            guard let path = words.first else { throw ControlError("bad-request", "share: give the Mac folder to share.") }
            words.removeFirst(); try done()
            let absolute = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path
            var args: [String: JSON] = ["path": .string(absolute), "readOnly": JSON(readOnly), "temporary": JSON(temporary)]
            if let label { args["name"] = .string(label) }
            return .request(op: .share, vm: name, args: args, screenshotFile: nil)
        case "unshare":
            let name = try vm()
            guard !words.isEmpty else { throw ControlError("bad-request", "unshare: name the folder.") }
            let folder = words.joined(separator: " "); words.removeAll()
            // A Mac path is passed whole so the app can match it.
            let key = folder.hasPrefix("/") || folder.hasPrefix(".") || folder.hasPrefix("~")
                ? URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL.path : folder
            return .request(op: .unshare, vm: name, args: ["folder": .string(key)], screenshotFile: nil)
        case "keep-awake":
            let name = try vm()
            var args: [String: JSON] = [:]
            if let state = words.first {
                guard state == "on" || state == "off" else { throw ControlError("bad-request", "keep-awake: say on or off.") }
                args["on"] = JSON(state == "on"); words.removeFirst()
            }
            try done()
            return .request(op: .keepAwake, vm: name, args: args, screenshotFile: nil)
        case "launch":
            let name = try vm()
            guard !words.isEmpty else { throw ControlError("bad-request", "launch: name the program.") }
            let program = words.joined(separator: " "); words.removeAll()
            return .request(op: .launch, vm: name, args: ["program": .string(program)], screenshotFile: nil)
        case "exec", "run":
            // Everything after `--` is the command, untouched.
            var command: [String] = []
            if let separator = words.firstIndex(of: "--") {
                command = Array(words[(separator + 1)...])
                words.removeSubrange(separator...)
            }
            let user = try option("--user"), timeout = try option("--timeout")
            let elevated = flag("--elevated")
            let name = try vm()
            if command.isEmpty { command = words; words.removeAll() }
            try done()
            guard !command.isEmpty else { throw ControlError("bad-request", "exec: give the command after --.") }
            var args: [String: JSON] = ["command": .string(command.joined(separator: " ")), "elevated": JSON(elevated)]
            if let user { args["user"] = .string(user) }
            if let timeout {
                guard let seconds = Int(timeout), seconds > 0 else { throw ControlError("bad-request", "--timeout needs a number of seconds.") }
                args["timeout"] = JSON(seconds)
            }
            return .request(op: .exec, vm: name, args: args, screenshotFile: nil)
        default:
            throw ControlError("bad-request", "Unknown command “\(command)”. `tandem help` lists the commands.")
        }
    }
}
