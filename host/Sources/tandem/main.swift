import Foundation
import TandemControl

// `tandem`: the user's command-line tool. It talks to the running Tandem app over the library's control
// socket (starting the app hidden when needed), so it controls the same VMs as the app's windows.
// `vmctl` remains the development tool that runs a VM inside its own process.

setvbuf(stdout, nil, _IOLBF, 0)
/// The version of the Tandem app this tool lives in (it sits in Tandem.app/Contents/Helpers).
let toolVersion: String = {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let info = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
    let plist = (NSDictionary(contentsOf: info) as? [String: Any]) ?? [:]
    return plist["CFBundleShortVersionString"] as? String ?? "development"
}()

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("tandem: \(message)\n".utf8))
    exit(code)
}

let invocation: CLIInvocation
do { invocation = try CLIParser.parse(Array(CommandLine.arguments.dropFirst())) }
catch { fail("\(error)\n\(CLIParser.usage.split(separator: "\n").first ?? "")", code: 2) }

let libraryRoot = ControlProtocol.libraryRoot()

func connection(_ client: ControlClient) throws -> ControlConnection {
    try ControlLauncher.connect(libraryRoot: libraryRoot, client: client, launch: invocation.launch)
}

switch invocation.action {
case .help:
    print(CLIParser.usage)
    exit(0)
case .version:
    print("tandem \(toolVersion) (control protocol \(ControlProtocol.version))")
    exit(0)
case .installInfo:
    let me = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
    print("tool:    \(me)")
    print("app:     \(ControlLauncher.appURL()?.path ?? "found by bundle id \(ControlLauncher.bundleIdentifier)")")
    print("library: \(libraryRoot.path)")
    print("socket:  \(ControlProtocol.socketURL(libraryRoot: libraryRoot).path)")
    exit(0)
case .mcp:
    var shared: ControlConnection?
    let server = MCPServer(version: toolVersion, aiAllowed: { ControlSettings.load(libraryRoot: libraryRoot).allowAITools }) { op, vm, args in
        if shared == nil { shared = try connection(.mcp) }
        do { return try shared!.send(op, vm: vm, args: args) }
        catch let error as ControlError where error.code == "unavailable" {
            // The app was quit since: connect again once.
            shared = try connection(.mcp)
            return try shared!.send(op, vm: vm, args: args)
        }
    }
    server.run()
    exit(0)
case .request(let op, let vm, let args, let screenshotFile):
    let result: JSON
    do { result = try connection(.cli).send(op, vm: vm, args: args) }
    catch let error as ControlError {
        if invocation.json {
            print(JSON.object(["ok": false, "error": .object(["code": .string(error.code), "message": .string(error.message), "detail": .optional(error.detail)])]).pretty())
        }
        fail(error.description, code: error.code == "refused" ? 77 : 1)
    } catch { fail(error.localizedDescription) }

    if op == .screenshot, let file = screenshotFile {
        guard let base64 = result["png"]?.string, let data = Data(base64Encoded: base64) else { fail("No picture came back.") }
        do { try data.write(to: URL(fileURLWithPath: file)) } catch { fail("Could not write \(file): \(error.localizedDescription)") }
        if invocation.json { print(JSON.object(["file": .string(file), "width": result["width"] ?? .null, "height": result["height"] ?? .null]).pretty()) }
        else { print("Wrote \(file) (\(result["width"]?.int ?? 0)x\(result["height"]?.int ?? 0))") }
        exit(0)
    }
    if invocation.json { print(result.pretty()); exit(op == .exec ? Int32(truncatingIfNeeded: result["exitCode"]?.int ?? 0) : 0) }
    print(Output.human(op, result), terminator: "")
    if op == .exec {
        if result["status"]?.string != "completed" { fail("the command did not complete: \(result["message"]?.string ?? result["status"]?.string ?? "")") }
        exit(Int32(truncatingIfNeeded: result["exitCode"]?.int ?? 0))
    }
    exit(0)
}
