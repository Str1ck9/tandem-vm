import Foundation
import VMCore

/// Makes a Windows installation that was set up under Parallels bootable on QEMU, without booting it.
///
/// Three things stop such an install from starting (found on a Windows 11 25H2 guest):
/// 1. Parallels presents the disk as SATA, so Windows disabled its NVMe driver at boot (`StartOverride`).
///    QEMU's ARM firmware cannot boot from SATA, so the disk has to be NVMe.
/// 2. Parallels Tools registers `prl_strg` as a lower filter on every disk; on other hardware it crashes the
///    kernel (`KERNEL_SECURITY_CHECK_FAILURE`).
/// 3. The other Parallels kernel drivers start at boot and have nothing to talk to.
///
/// The repair is a script on a small disk next to a Windows installer ISO. Windows Setup runs it from the answer
/// file's `windowsPE` pass, and the script powers the VM off when it has succeeded.
public enum WindowsImportRepair {
    public static let scriptName = "tandem-repair.cmd"
    public static let logName = "tandem-import.log"
    public static let mediaLabel = "TANDEMREPAIR"
    public static let agentName = "tandem-agent.exe"
    public static let setupScriptName = "tandem-setup.cmd"
    public static let taskFileName = "tandem-agent-task.xml"
    public static let taskName = "Tandem Guest Agent"

    /// Runs once as SYSTEM on the first boot after the repair: registers the agent's scheduled task, then removes itself.
    public static var setupScript: String {
        """
        @echo off
        mkdir "%ProgramData%\\Tandem" >nul 2>&1
        set LOG=%ProgramData%\\Tandem\\setup.log
        echo Tandem setup %DATE% %TIME% > "%LOG%"
        schtasks /create /tn "\(taskName)" /xml "%ProgramFiles%\\Tandem\\\(taskFileName)" /f >> "%LOG%" 2>&1
        reg delete HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run /v TandemAgent /f >> "%LOG%" 2>&1
        sc delete TandemSetup >> "%LOG%" 2>&1

        """.replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// Scheduled task: start the agent when any user signs in, elevated where the user is an administrator,
    /// with no run-time limit (the default limit would stop it after three days).
    public static var taskDefinition: String {
        """
        <?xml version="1.0" encoding="UTF-16"?>
        <Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
          <RegistrationInfo><Description>Tandem guest agent: clipboard, clock and shutdown integration with the host.</Description></RegistrationInfo>
          <Triggers><LogonTrigger><Enabled>true</Enabled></LogonTrigger></Triggers>
          <Principals><Principal id="Author"><GroupId>S-1-5-32-545</GroupId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
          <Settings>
            <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
            <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
            <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
            <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
            <Enabled>true</Enabled>
            <Hidden>false</Hidden>
          </Settings>
          <Actions Context="Author"><Exec><Command>"%ProgramFiles%\\Tandem\\\(agentName)"</Command></Exec></Actions>
        </Task>

        """.replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// Parallels Tools kernel drivers, as service names.
    public static let parallelsDrivers = ["prl_dd", "prl_dearm", "prl_fs", "prl_memdev", "prl_mouf", "prl_strg", "prl_tg", "prl_virt_disk_balloon"]

    /// Device classes whose filter lists are cleaned: disk drives, volumes, SCSI adapters, mice, keyboards, display.
    static let filterClasses = [
        "{4d36e967-e325-11ce-bfc1-08002be10318}", "{71a27cdd-812a-11d0-bec7-08002be2092f}",
        "{4d36e97b-e325-11ce-bfc1-08002be10318}", "{4d36e96f-e325-11ce-bfc1-08002be10318}",
        "{4d36e96b-e325-11ce-bfc1-08002be10318}", "{4d36e968-e325-11ce-bfc1-08002be10318}",
    ]

    public static var answerFile: String {
        let command = "cmd /c \"for %i in (C D E F G H I J K L M N) do @if exist %i:\\\(scriptName) call %i:\\\(scriptName)\""
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <settings pass="windowsPE">
            <component name="Microsoft-Windows-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
              <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                  <Order>1</Order>
                  <Description>Repair imported Windows</Description>
                  <Path>\(AutounattendBuilder.escape(command))</Path>
                </RunSynchronousCommand>
              </RunSynchronous>
            </component>
          </settings>
        </unattend>

        """
    }

    /// The repair script. It only powers off (`wpeutil shutdown`) when the registry changes all succeeded;
    /// on any failure it returns to Setup, and the host sees that as a timeout.
    public static var script: String {
        let drivers = parallelsDrivers.joined(separator: " ")
        let classes = filterClasses.joined(separator: " ")
        return """
        @echo off
        setlocal enabledelayedexpansion
        set WIN=
        for %%L in (C D E F G H I J K L M N O P) do if not defined WIN if exist %%L:\\Windows\\System32\\config\\SYSTEM set WIN=%%L:
        if not defined WIN exit /b 1
        set LOG=%WIN%\\\(logName)
        echo Tandem import repair %DATE% %TIME% > "%LOG%"

        reg load HKLM\\TANDEMSYS %WIN%\\Windows\\System32\\config\\SYSTEM >> "%LOG%" 2>&1
        if errorlevel 1 exit /b 1
        set CUR=1
        for /f "tokens=3" %%C in ('reg query HKLM\\TANDEMSYS\\Select /v Current ^| find "REG_DWORD"') do set /a CUR=%%C
        set CS=HKLM\\TANDEMSYS\\ControlSet00%CUR%
        echo control set %CS% >> "%LOG%"
        set FAILED=

        rem 1. Let the NVMe driver start at boot.
        reg add %CS%\\Services\\stornvme /v Start /t REG_DWORD /d 0 /f >> "%LOG%" 2>&1
        if errorlevel 1 set FAILED=1
        reg delete %CS%\\Services\\stornvme\\StartOverride /f >> "%LOG%" 2>&1

        rem 2. Take Parallels drivers out of the device class filter lists.
        for %%K in (\(classes)) do for %%V in (UpperFilters LowerFilters) do call :clean "%CS%\\Control\\Class\\%%K" %%V

        rem 3. Stop Parallels kernel drivers from loading.
        for %%S in (\(drivers)) do (
          reg query %CS%\\Services\\%%S >nul 2>&1
          if not errorlevel 1 (
            reg add %CS%\\Services\\%%S /v Start /t REG_DWORD /d 4 /f >> "%LOG%" 2>&1
            if errorlevel 1 set FAILED=1
          )
        )

        reg unload HKLM\\TANDEMSYS >> "%LOG%" 2>&1
        if errorlevel 1 set FAILED=1

        rem 4. Install the guest agent. The virtio-serial port can only be opened by an elevated process, so the
        rem agent runs from a scheduled task (at logon, highest privileges, in the user's session for the clipboard).
        rem A task cannot be registered offline, so a one-shot service registers it as SYSTEM on the next boot.
        if exist "%~dp0\(agentName)" (
          rem An agent installed under the app's old name would compete for the channel; without its file its task does nothing.
          if exist "%WIN%\\Program Files\\Berth" rmdir /s /q "%WIN%\\Program Files\\Berth" >> "%LOG%" 2>&1
          mkdir "%WIN%\\Program Files\\Tandem" >nul 2>&1
          copy /y "%~dp0\(agentName)" "%WIN%\\Program Files\\Tandem\\\(agentName)" >> "%LOG%" 2>&1
          copy /y "%~dp0\(setupScriptName)" "%WIN%\\Program Files\\Tandem\\\(setupScriptName)" >> "%LOG%" 2>&1
          copy /y "%~dp0\(taskFileName)" "%WIN%\\Program Files\\Tandem\\\(taskFileName)" >> "%LOG%" 2>&1
          reg load HKLM\\TANDEMSYS %WIN%\\Windows\\System32\\config\\SYSTEM >> "%LOG%" 2>&1
          reg add %CS%\\Services\\TandemSetup /v Type /t REG_DWORD /d 16 /f >> "%LOG%" 2>&1
          reg add %CS%\\Services\\TandemSetup /v Start /t REG_DWORD /d 2 /f >> "%LOG%" 2>&1
          reg add %CS%\\Services\\TandemSetup /v ErrorControl /t REG_DWORD /d 0 /f >> "%LOG%" 2>&1
          reg add %CS%\\Services\\TandemSetup /v ObjectName /t REG_SZ /d LocalSystem /f >> "%LOG%" 2>&1
          reg add %CS%\\Services\\TandemSetup /v ImagePath /t REG_EXPAND_SZ /d "%%SystemRoot%%\\System32\\cmd.exe /c \\"\\"%%ProgramFiles%%\\Tandem\\\(setupScriptName)\\"\\"" /f >> "%LOG%" 2>&1
          reg unload HKLM\\TANDEMSYS >> "%LOG%" 2>&1
        )

        rem 5. Add virtio drivers (network, serial channel, display). Not fatal: Windows boots without them.
        if exist "%~dp0drivers" dism /image:%WIN%\\ /add-driver /driver:"%~dp0drivers" /recurse >> "%LOG%" 2>&1

        if defined FAILED (
          echo FAILED >> "%LOG%"
          exit /b 1
        )
        echo OK >> "%LOG%"
        wpeutil shutdown
        exit /b 0

        :clean
        set VAL=
        for /f "tokens=2,*" %%A in ('reg query %1 /v %2 2^>nul ^| find "REG_MULTI_SZ"') do set VAL=%%B
        if not defined VAL goto :eof
        set NEW=!VAL!
        for %%S in (\(drivers)) do (
          set NEW=!NEW:%%S\\0=!
          set NEW=!NEW:\\0%%S=!
          if /i "!NEW!"=="%%S" set NEW=
        )
        if "!NEW!"=="!VAL!" goto :eof
        echo %1 %2: !VAL! -^> !NEW! >> "%LOG%"
        if defined NEW (reg add %1 /v %2 /t REG_MULTI_SZ /d "!NEW!" /f >> "%LOG%" 2>&1) else (reg delete %1 /v %2 /f >> "%LOG%" 2>&1)
        if errorlevel 1 set FAILED=1
        goto :eof

        """.replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// Lays out the repair disk's files. `driversDirectory` is a folder of ARM64 `.inf` trees, copied to `drivers/`.
    public static func stage(in directory: URL, driversDirectory: URL? = nil, agentExecutable: URL? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(answerFile.utf8).write(to: directory.appendingPathComponent("autounattend.xml"))
        try Data(script.utf8).write(to: directory.appendingPathComponent(scriptName))
        if let drivers = driversDirectory {
            guard fm.fileExists(atPath: drivers.path) else { throw VMError("Driver folder is missing: \(drivers.path)") }
            try fm.copyItem(at: drivers, to: directory.appendingPathComponent("drivers"))
        }
        if let agent = agentExecutable {
            guard fm.fileExists(atPath: agent.path) else { throw VMError("Guest agent is missing: \(agent.path)") }
            try fm.copyItem(at: agent, to: directory.appendingPathComponent(agentName))
            try Data(setupScript.utf8).write(to: directory.appendingPathComponent(setupScriptName))
            // Task Scheduler wants UTF-16 with a byte-order mark.
            var xml = Data([0xFF, 0xFE])
            xml.append(taskDefinition.data(using: .utf16LittleEndian)!)
            try xml.write(to: directory.appendingPathComponent(taskFileName))
        }
    }

    /// Builds the repair disk image at `output`.
    public static func buildMedia(at output: URL, driversDirectory: URL? = nil, agentExecutable: URL? = nil) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("tandem-repair-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try stage(in: staging, driversDirectory: driversDirectory, agentExecutable: agentExecutable)
        try? fm.removeItem(at: output)
        let result = try ToolRun.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                     ["makehybrid", "-quiet", "-iso", "-joliet", "-udf", "-default-volume-name", mediaLabel, "-o", output.path, staging.path],
                                     timeout: ToolRun.Limit.image, output: .discard)
        guard result.succeeded else { throw ToolRun.failed(result, "Could not build the Windows repair disk.") }
    }
}
