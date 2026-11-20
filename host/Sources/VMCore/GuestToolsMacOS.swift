import Foundation

/// Tandem's guest tools for macOS guests: the agent (built by `scripts/build-agent.sh`), an installer
/// package made from it, and the disc that carries both into the guest.
///
/// The agent runs as root from a LaunchDaemon. Apple's framework already resizes the display with the
/// window and mounts shared folders ("My Shared Files"); the agent adds the clipboard, a clean shutdown
/// and restart, the clock after a resume, the guest's address, activity for the idle timer and commands
/// from the Mac.
extension GuestTools {
    public static let macOSAgentName = "tandem-agent-macos"
    public static let macOSDiscName = "guest-tools-macos.iso"
    public static let macOSVolumeName = "Tandem Tools"
    public static let macOSPackageName = "Install Tandem Tools.pkg"
    public static let macOSDaemonLabel = TandemIdentity.guestAgent
    /// Where the package puts the agent inside the guest.
    public static let macOSAgentInstallPath = "/Library/Application Support/Tandem Agent/tandem-agent"

    public static var macOSAgent: URL? { locate(macOSAgentName) }

    static var macOSDaemonPlist: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(macOSDaemonLabel)</string>
          <key>ProgramArguments</key>
          <array><string>\(macOSAgentInstallPath)</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>ThrottleInterval</key><integer>5</integer>
          <key>StandardErrorPath</key><string>/var/log/tandem-agent.log</string>
        </dict>
        </plist>

        """
    }

    /// Run by Installer after the files are in place, and by `install.sh` for a Terminal install.
    static let macOSPostinstall = """
    #!/bin/sh
    # Starts (or restarts) the Tandem guest agent.
    label=\(macOSDaemonLabel)
    plist=/Library/LaunchDaemons/$label.plist
    chown root:wheel "$plist" && chmod 644 "$plist"
    /bin/launchctl bootout system/$label 2>/dev/null || true
    /bin/launchctl enable system/$label
    /bin/launchctl bootstrap system "$plist"
    exit 0

    """

    /// For a guest without Installer at hand (or a user who prefers Terminal): `sudo sh install.sh`.
    static let macOSInstallScript = """
    #!/bin/sh
    # Tandem guest tools for macOS. In Terminal:  sudo sh "/Volumes/\(macOSVolumeName)/install.sh"
    set -eu
    if [ "$(id -u)" != 0 ]; then echo "Run this as root:  sudo sh $0" >&2; exit 1; fi
    here="$(cd "$(dirname "$0")" && pwd)"
    dir="\((macOSAgentInstallPath as NSString).deletingLastPathComponent)"
    mkdir -p "$dir"
    cp "$here/tandem-agent" "$dir/tandem-agent.new"
    chmod 755 "$dir/tandem-agent.new"
    mv -f "$dir/tandem-agent.new" "$dir/tandem-agent"
    cp "$here/\(macOSDaemonLabel).plist" /Library/LaunchDaemons/\(macOSDaemonLabel).plist
    sh "$here/postinstall"
    echo "Tandem guest tools are installed and running."

    """

    static let macOSUninstallScript = """
    #!/bin/sh
    # Removes the Tandem guest tools.  sudo sh "/Volumes/\(macOSVolumeName)/uninstall.sh"
    set -u
    if [ "$(id -u)" != 0 ]; then echo "Run this as root:  sudo sh $0" >&2; exit 1; fi
    /bin/launchctl bootout system/\(macOSDaemonLabel) 2>/dev/null || true
    rm -f /Library/LaunchDaemons/\(macOSDaemonLabel).plist
    rm -rf "\((macOSAgentInstallPath as NSString).deletingLastPathComponent)"
    /usr/sbin/pkgutil --forget \(macOSDaemonLabel).pkg >/dev/null 2>&1 || true
    echo "Tandem guest tools are removed."

    """

    static let macOSReadme = """
    Tandem guest tools for macOS

    Double-click "\(macOSPackageName)" and follow Installer. It needs an administrator's password.
    (In Terminal instead:  sudo sh "/Volumes/\(macOSVolumeName)/install.sh")

    The tools share the clipboard (text) with the Mac, let the Mac shut this Mac down or restart it
    cleanly, put the clock right after the VM was suspended, report its address and activity, and run
    commands the Mac sends when you allow that in Tandem. Shared folders and the window size need no
    tools: macOS shows the Mac's folders as "My Shared Files" and follows the window by itself.

    The tools update themselves from the Mac afterwards. To remove them:
        sudo sh "/Volumes/\(macOSVolumeName)/uninstall.sh"

    """

    /// Lays out the package's payload (`root`) and scripts (`scripts`). Separate so it can be tested
    /// without `pkgbuild`.
    public static func stageMacOSPackage(agent: URL, root: URL, scripts: URL) throws {
        let fm = FileManager.default
        let agentDir = root.appendingPathComponent(String(macOSAgentInstallPath.dropFirst())).deletingLastPathComponent()
        try fm.createDirectory(at: agentDir, withIntermediateDirectories: true)
        let installed = agentDir.appendingPathComponent("tandem-agent")
        try fm.copyItem(at: agent, to: installed)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.path)
        let daemons = root.appendingPathComponent("Library/LaunchDaemons", isDirectory: true)
        try fm.createDirectory(at: daemons, withIntermediateDirectories: true)
        try Data(macOSDaemonPlist.utf8).write(to: daemons.appendingPathComponent("\(macOSDaemonLabel).plist"))
        try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
        let post = scripts.appendingPathComponent("postinstall")
        try Data(macOSPostinstall.utf8).write(to: post)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: post.path)
    }

    /// Lays out the disc: the package (when one was made), the agent with Terminal install scripts, and
    /// a README.
    public static func stageMacOSDisc(agent: URL, package: URL?, in directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if let package { try fm.copyItem(at: package, to: directory.appendingPathComponent(macOSPackageName)) }
        let files: [(String, String, Int)] = [
            ("install.sh", macOSInstallScript, 0o755), ("uninstall.sh", macOSUninstallScript, 0o755),
            ("postinstall", macOSPostinstall, 0o755), ("\(macOSDaemonLabel).plist", macOSDaemonPlist, 0o644),
            ("README.txt", macOSReadme, 0o644),
        ]
        for (name, text, mode) in files {
            let url = directory.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        try fm.copyItem(at: agent, to: directory.appendingPathComponent("tandem-agent"))
    }

    /// The macOS guest tools disc (a hybrid image the guest mounts as "Tandem Tools"), built on first
    /// use and again whenever the agent build is newer. Nil when this host has no macOS agent build.
    public static func macOSDisc(agent: URL? = macOSAgent, output: URL? = nil, version: String = "1.0") throws -> URL? {
        guard let agent else { return nil }
        let fm = FileManager.default
        let folder = ProcessInfo.processInfo.environment["TANDEM_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? supportDirectory
        let output = output ?? folder.appendingPathComponent(macOSDiscName)
        func modified(_ url: URL) -> Date? { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        if let built = modified(output), let source = modified(agent), built >= source { return output }

        let work = fm.temporaryDirectory.appendingPathComponent("tandem-macos-tools-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        // The package. `pkgbuild` is part of macOS; should it fail, the disc still has install.sh.
        let root = work.appendingPathComponent("root"), scripts = work.appendingPathComponent("scripts")
        try stageMacOSPackage(agent: agent, root: root, scripts: scripts)
        let package = work.appendingPathComponent("tools.pkg")
        let built = try? ToolRun.run(URL(fileURLWithPath: "/usr/bin/pkgbuild"),
                                     ["--quiet", "--root", root.path, "--scripts", scripts.path, "--identifier", "\(macOSDaemonLabel).pkg",
                                      "--version", version, "--install-location", "/", "--ownership", "recommended", package.path],
                                     timeout: ToolRun.Limit.image, output: .discard)
        let disc = work.appendingPathComponent("disc")
        try stageMacOSDisc(agent: agent, package: built?.succeeded == true ? package : nil, in: disc)

        try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fresh = output.deletingPathExtension().appendingPathExtension("new.iso")
        try? fm.removeItem(at: fresh)
        // HFS+ for the Mac guest (it keeps the package's name and the scripts' modes), ISO and Joliet besides.
        let result = try ToolRun.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                     ["makehybrid", "-quiet", "-hfs", "-iso", "-joliet", "-hfs-volume-name", macOSVolumeName,
                                      "-default-volume-name", "TANDEM_TOOLS", "-o", fresh.path, disc.path],
                                     timeout: ToolRun.Limit.image, output: .discard)
        guard result.succeeded else { throw ToolRun.failed(result, "Could not build the macOS guest tools disc.") }
        _ = try? fm.removeItem(at: output)
        try fm.moveItem(at: fresh, to: output)
        return output
    }

    // MARK: When the disc is attached

    /// Settles, at a start, whether a macOS guest gets the tools disc. The disc is asked for when a macOS
    /// VM is made and from Actions > Install Tandem Tools…; it goes in at every cold start until the tools
    /// have answered since. A resume keeps exactly what the VM was saved with (`toolsDiscAttached`),
    /// because a saved state only restores onto the same devices. Returns true when `info` changed.
    @discardableResult
    public static func settleMacOSDiscRequest(_ info: inout GuestToolsInfo, resuming: Bool) -> Bool {
        guard !resuming else { return false }
        let before = info
        if let requested = info.toolsDiscRequested, let seen = info.lastSeen, seen > requested {
            info.toolsDiscRequested = nil
        }
        info.toolsDiscAttached = info.toolsDiscRequested != nil ? true : nil
        return info != before
    }

    /// Whether this start of a macOS guest gets the disc: what the last cold start settled.
    public static func attachesMacOSDisc(_ config: VMConfig) -> Bool {
        config.guestOS == .macos && config.guestTools.toolsDiscAttached == true
    }
}
