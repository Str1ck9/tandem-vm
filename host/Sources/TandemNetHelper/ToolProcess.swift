import Foundation
import IdentityCore
import Security

// MARK: Running a tool as root, verified
//
// In bundle mode the tools the helper runs as root (qemu-nbd, usbredirect) live inside Tandem.app, a
// folder its owner may write to. Checking the file's signature and then starting it leaves a gap: the
// file can be swapped between the check and the start. So the tool is started suspended, and the
// signature checked is the one of the program the kernel actually loaded into that process. Only if it
// is the right program of the helper's own team, with the hardened runtime (so dyld loads no library
// that the same team did not sign, and ignores DYLD_ variables), does it run; otherwise it is killed
// before it has executed a single instruction.
//
// The child also inherits no descriptor but stdin, stdout and stderr (the helper's control and bridge
// sockets stay in the helper), gets a fixed environment, and has its stderr read continuously, so a
// chatty tool can never block on a full pipe.

/// The code signing identifier `scripts/sign-app.sh` gives a bundled tool: `<prefix>.<file name>`, with the
/// build's bundle prefix (`TandemIdentity.prefix`, read from the Info.plist of the app this helper sits in).
func expectedIdentifier(forTool path: String) -> String { TandemIdentity.tool((path as NSString).lastPathComponent) }

/// The requirement a tool run as root must meet: this tool's identifier, signed by `team`.
func toolRequirement(identifier: String, team: String) -> String? {
    guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
          identifier.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return nil }
    return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
}

/// Code signing flags of the hardened runtime and of library validation (cs_blobs.h).
let codeSignatureRuntimeFlag: UInt32 = 0x10000
let codeSignatureLibraryValidationFlag: UInt32 = 0x2000
/// Entitlements that would let other code into a root process despite the hardened runtime.
let unsafeRootEntitlements = ["com.apple.security.cs.disable-library-validation",
                              "com.apple.security.cs.allow-dyld-environment-variables",
                              "com.apple.security.get-task-allow"]

/// Why a signing description is not good enough for a program run as root, or nil when it is.
/// Pure, so it can be tested: `flags` are the code directory's flags, `entitlements` its entitlements.
func rootToolRefusal(flags: UInt32, entitlements: [String: Any]) -> String? {
    if flags & (codeSignatureRuntimeFlag | codeSignatureLibraryValidationFlag) == 0 {
        return "it is not signed with the hardened runtime"
    }
    for key in unsafeRootEntitlements where (entitlements[key] as? Bool) == true {
        return "its signature carries \(key)"
    }
    return nil
}

/// A child process started with posix_spawn.
final class ToolProcess: @unchecked Sendable {
    let pid: pid_t
    private let lock = NSLock()
    private var exitStatus: Int32?
    private var errorTail = Data()
    private let errorReader: FileHandle
    private let readerDone = DispatchSemaphore(value: 0)

    enum Failure: Error, CustomStringConvertible {
        case spawn(String)
        case untrusted(String)
        var description: String {
            switch self {
            case .spawn(let text): return text
            case .untrusted(let text): return text
            }
        }
    }

    /// Starts `path`. With `team`, the program the kernel loaded must be signed by that team with the
    /// tool's identifier and the hardened runtime, or it is killed before it runs.
    init(path: String, arguments: [String], team: String?) throws {
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else { throw Failure.spawn("pipe() failed: \(errnoText())") }
        let readFD = pipeFDs[0], writeFD = pipeFDs[1]
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var flags = Int32(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        if team != nil { flags |= Int32(POSIX_SPAWN_START_SUSPENDED) }
        posix_spawnattr_setflags(&attributes, Int16(flags))
        // Default handling for every signal (the helper ignores SIGPIPE, SIGTERM and SIGINT itself) and
        // nothing blocked, so SIGTERM ends the tool.
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all); sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)

        let argumentStrings: [String] = [path] + arguments
        let environmentStrings: [String] = ["PATH=/usr/bin:/bin"]
        let argv: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var child: pid_t = 0
        let rc = posix_spawn(&child, path, &actions, &attributes, argv, envp)
        close(writeFD)
        guard rc == 0 else {
            close(readFD)
            throw Failure.spawn("cannot start \((path as NSString).lastPathComponent): \(String(cString: strerror(rc)))")
        }
        pid = child
        errorReader = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)

        if let team {
            if let problem = Self.verifyRunning(pid: child, path: path, team: team) {
                kill(child, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(child, &status, 0)
                readerDone.signal()
                throw Failure.untrusted("refused to run \((path as NSString).lastPathComponent) as root: \(problem)")
            }
            kill(child, SIGCONT)
        }
        let thread = Thread { [self] in readErrors() }
        thread.name = "tool-stderr"
        thread.start()
    }

    /// Checks the code the kernel mapped into the suspended child. Nil when it may run.
    static func verifyRunning(pid: pid_t, path: String, team: String) -> String? {
        guard let text = toolRequirement(identifier: expectedIdentifier(forTool: path), team: team) else { return "no valid requirement" }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return "no valid requirement" }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            return "its signature could not be read"
        }
        let status = SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement)
        guard status == errSecSuccess else { return "it is not \(expectedIdentifier(forTool: path)) signed by team \(team) (\(status))" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return "its signature could not be read" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return "its signature could not be read" }
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        return rootToolRefusal(flags: flags, entitlements: entitlements)
    }

    private func readErrors() {
        defer { readerDone.signal() }
        while true {
            let chunk = errorReader.availableData
            if chunk.isEmpty { return }
            lock.withLock {
                errorTail.append(chunk)
                if errorTail.count > 8192 { errorTail = Data(errorTail.suffix(4096)) }
            }
        }
    }

    /// The last lines the tool wrote to stderr (once it has ended, all of them up to a few KB).
    func errorText(lines: Int = 3) -> String {
        if !isRunning { _ = readerDone.wait(timeout: .now() + 1) }
        let text = lock.withLock { String(decoding: errorTail, as: UTF8.self) }
        return text.split(separator: "\n").suffix(lines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    var isRunning: Bool {
        lock.withLock {
            if exitStatus != nil { return false }
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result < 0 && errno == ECHILD) { exitStatus = status; return false }
            return true
        }
    }

    /// The exit code once the tool has ended normally.
    var exitCode: Int32? {
        guard !isRunning, let status = lock.withLock({ exitStatus }), status & 0x7f == 0 else { return nil }
        return (status >> 8) & 0xff
    }

    /// SIGTERM, up to `grace` seconds, then SIGKILL; never waits forever.
    func end(grace: TimeInterval = 5) {
        guard isRunning else { return }
        kill(pid, SIGTERM)
        var deadline = Date().addingTimeInterval(grace)
        while isRunning, Date() < deadline { usleep(20_000) }
        guard isRunning else { return }
        kill(pid, SIGKILL)
        deadline = Date().addingTimeInterval(2)
        while isRunning, Date() < deadline { usleep(20_000) }
    }
}
