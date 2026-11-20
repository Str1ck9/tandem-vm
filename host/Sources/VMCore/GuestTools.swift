import Foundation

/// The guest agent builds this host carries, and the disc a Linux guest installs its agent from.
public enum GuestTools {
    public static let windowsAgentName = "tandem-agent.exe"
    public static let linuxAgentName = "tandem-agent-linux"
    public static let linuxISOName = "guest-tools-linux.iso"
    public static let linuxVolumeName = "TANDEM_TOOLS"

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tandem", isDirectory: true)
    }

    /// Inside the app bundle, or in Application Support (where a development build keeps them).
    /// `TANDEM_GUEST_TOOLS_DIR` comes first: a development build tests its own agents with it, without
    /// replacing the copies every other VM updates itself from.
    static func locate(_ name: String) -> URL? {
        let override = ProcessInfo.processInfo.environment["TANDEM_GUEST_TOOLS_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
        let candidates = [override, Bundle.main.resourceURL?.appendingPathComponent(name), supportDirectory.appendingPathComponent(name)]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static var windowsAgent: URL? { locate(windowsAgentName) }
    public static var linuxAgent: URL? { locate(linuxAgentName) }

    /// Installs the agent as a system service (systemd or OpenRC). Run as root from the mounted disc.
    public static let linuxInstallScript = """
    #!/bin/sh
    # Tandem guest tools for Linux. Run as root:  sudo sh install.sh
    set -eu
    if [ "$(id -u)" != 0 ]; then echo "Run this as root:  sudo sh $0" >&2; exit 1; fi
    here="$(cd "$(dirname "$0")" && pwd)"
    mkdir -p /usr/local/bin
    cp "$here/tandem-agent" /usr/local/bin/tandem-agent.new
    chmod 755 /usr/local/bin/tandem-agent.new
    mv -f /usr/local/bin/tandem-agent.new /usr/local/bin/tandem-agent
    if [ -d /run/systemd/system ]; then
      cat > /etc/systemd/system/tandem-agent.service <<'UNIT'
    [Unit]
    Description=Tandem guest agent (clock, shared folders, clipboard, shutdown)

    [Service]
    ExecStart=/usr/local/bin/tandem-agent
    Restart=always
    RestartSec=2

    [Install]
    WantedBy=multi-user.target
    UNIT
      systemctl daemon-reload
      systemctl enable tandem-agent.service
      systemctl restart tandem-agent.service
    elif command -v rc-update >/dev/null 2>&1; then
      cat > /etc/init.d/tandem-agent <<'UNIT'
    #!/sbin/openrc-run
    description="Tandem guest agent"
    command=/usr/local/bin/tandem-agent
    command_background=true
    pidfile=/run/tandem-agent.pid
    output_log=/var/log/tandem-agent.log
    error_log=/var/log/tandem-agent.log
    UNIT
      chmod 755 /etc/init.d/tandem-agent
      rc-update add tandem-agent default
      rc-service tandem-agent restart
    else
      echo "Installed /usr/local/bin/tandem-agent, but this system has neither systemd nor OpenRC." >&2
      echo "Start it as root at boot yourself." >&2
      exit 1
    fi
    echo "Tandem guest tools are installed and running."

    """

    static let linuxReadme = """
    Tandem guest tools for Linux (ARM64)

    In a terminal, from the folder where this disc is mounted:

        sudo sh install.sh

    If the disc is not mounted:

        sudo mount -o ro /dev/sr0 /mnt && sudo sh /mnt/install.sh

    The agent keeps the clock right, mounts the Mac's shared folders under /media/mac,
    shares the clipboard (needs xclip or wl-clipboard), follows the window size (needs xrandr)
    and lets the Mac shut the guest down cleanly. It updates itself from the Mac afterwards.

    """

    /// Lays the disc's files out in a folder. Separate from `linuxISO` so it can be tested without `hdiutil`.
    public static func stageLinux(agent: URL, in directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.copyItem(at: agent, to: directory.appendingPathComponent("tandem-agent"))
        try Data(linuxInstallScript.utf8).write(to: directory.appendingPathComponent("install.sh"))
        try Data(linuxReadme.utf8).write(to: directory.appendingPathComponent("README.txt"))
    }

    /// The Linux guest tools disc, built on first use and again whenever the agent build is newer.
    /// Nil when this host has no Linux agent build.
    public static func linuxISO(agent: URL? = linuxAgent, output: URL? = nil) throws -> URL? {
        guard let agent else { return nil }
        let fm = FileManager.default
        // A test library (TANDEM_HOME) keeps its own disc, so a test build never rewrites the real one.
        let folder = ProcessInfo.processInfo.environment["TANDEM_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? supportDirectory
        let output = output ?? folder.appendingPathComponent(linuxISOName)
        func modified(_ url: URL) -> Date? { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        if let built = modified(output), let source = modified(agent), built >= source { return output }

        let staging = fm.temporaryDirectory.appendingPathComponent("tandem-tools-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try stageLinux(agent: agent, in: staging)
        try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        // hdiutil adds ".iso" to any other name, so the temporary file keeps that extension.
        let fresh = output.deletingPathExtension().appendingPathExtension("new.iso")
        try? fm.removeItem(at: fresh)
        // Joliet keeps the long lower-case names a Linux guest expects.
        let result = try ToolRun.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                     ["makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", linuxVolumeName, "-o", fresh.path, staging.path],
                                     timeout: ToolRun.Limit.image, output: .discard)
        guard result.succeeded else { throw ToolRun.failed(result, "Could not build the Linux guest tools disc.") }
        _ = try? fm.removeItem(at: output)
        try fm.moveItem(at: fresh, to: output)
        return output
    }
}
