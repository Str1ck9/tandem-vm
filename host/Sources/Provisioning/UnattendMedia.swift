import Foundation
import VMCore

/// Builds the second install disk: answer file, first-logon script, drivers and the guest agent.
public enum UnattendMediaBuilder {
    public struct Contents: Sendable {
        public var options: WindowsUnattendOptions
        /// Folder of Windows ARM64 drivers (`.inf` trees), copied to `drivers/`. Optional.
        public var driversDirectory: URL?
        /// Windows build of the guest agent, copied to `tandem-agent.exe`. Optional.
        public var agentExecutable: URL?
        public init(options: WindowsUnattendOptions, driversDirectory: URL? = nil, agentExecutable: URL? = nil) {
            self.options = options; self.driversDirectory = driversDirectory; self.agentExecutable = agentExecutable
        }
    }

    public static let fileName = "unattend.iso"

    /// Lays the files out in a staging folder. Separate from `build` so it can be tested without `hdiutil`.
    public static func stage(_ contents: Contents, in directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Windows Setup looks for this exact name in the root of removable media.
        try Data(try AutounattendBuilder.xml(contents.options).utf8).write(to: directory.appendingPathComponent("autounattend.xml"))
        // PowerShell 5 reads scripts as ANSI unless they carry a BOM.
        var script = Data([0xEF, 0xBB, 0xBF])
        script.append(Data(AutounattendBuilder.firstLogonScript(for: contents.options).replacingOccurrences(of: "\n", with: "\r\n").utf8))
        try script.write(to: directory.appendingPathComponent("firstlogon.ps1"))
        if let drivers = contents.driversDirectory {
            guard fm.fileExists(atPath: drivers.path) else { throw VMError("Driver folder is missing: \(drivers.path)") }
            try fm.copyItem(at: drivers, to: directory.appendingPathComponent("drivers"))
        }
        if let agent = contents.agentExecutable {
            guard fm.fileExists(atPath: agent.path) else { throw VMError("Guest agent is missing: \(agent.path)") }
            try fm.copyItem(at: agent, to: directory.appendingPathComponent("tandem-agent.exe"))
            // The scheduled task that starts the agent at logon, in the form schtasks reads (UTF-16 with a mark).
            var task = Data([0xFF, 0xFE])
            task.append(WindowsImportRepair.taskDefinition.data(using: .utf16LittleEndian)!)
            try task.write(to: directory.appendingPathComponent(WindowsImportRepair.taskFileName))
        }
    }

    /// Writes `unattend.iso` into the bundle and returns its URL. Replaces an existing one.
    @discardableResult
    public static func build(_ contents: Contents, for bundle: VMBundle) throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("tandem-unattend-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try stage(contents, in: staging)
        let output = bundle.url.appendingPathComponent(fileName)
        try? fm.removeItem(at: output)
        let result = try ToolRun.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                     ["makehybrid", "-quiet", "-iso", "-joliet", "-udf",
                                      "-default-volume-name", AutounattendBuilder.mediaLabel, "-o", output.path, staging.path],
                                     timeout: ToolRun.Limit.image, output: .discard)
        guard result.succeeded else { throw ToolRun.failed(result, "Could not build the unattended-install disk.") }
        // It holds the account's password until the install has finished: this user only.
        _ = chmod(output.path, 0o600)
        return output
    }
}
