import Foundation
import VMCore

/// Answers for an unattended Windows 11 ARM install.
///
/// Run on 2026-11-14 with the Windows 11 ARM64 disc of build 26300 (Home, Home Single Language, Pro):
/// Setup partitioned the disk, installed Pro, created the account and signed it in without a question.
public struct WindowsUnattendOptions: Equatable, Sendable {
    public var computerName: String
    public var userName: String
    /// Stored in plain text on the install media inside the VM bundle.
    public var password: String
    public var locale: String
    public var timeZone: String
    /// Image name inside the installer, for example "Windows 11 Pro".
    public var edition: String
    /// Optional. Without one, Microsoft's generic key for the edition is used: Setup needs a key to pick
    /// an edition from a multi-edition disc, and a generic key installs without activating.
    public var productKey: String?
    /// Setup refuses to install without Secure Boot; QEMU's stock firmware has none enrolled.
    public var bypassSecureBootCheck: Bool
    /// Sign the account in at every start, not only the first. Windows keeps the password for that in
    /// the registry (Winlogon `DefaultPassword`), readable by administrators of the guest.
    public var autoLogin: Bool

    public init(computerName: String = "TANDEM-VM", userName: String, password: String, locale: String = "en-US",
                timeZone: String = "UTC", edition: String = "Windows 11 Pro", productKey: String? = nil,
                bypassSecureBootCheck: Bool = true, autoLogin: Bool = true) {
        self.computerName = computerName; self.userName = userName; self.password = password; self.locale = locale
        self.timeZone = timeZone; self.edition = edition; self.productKey = productKey
        self.bypassSecureBootCheck = bypassSecureBootCheck
        self.autoLogin = autoLogin
    }

    /// Microsoft's published generic keys. They select an edition during Setup and never activate Windows.
    public static let genericKeys = [
        "Windows 11 Pro": "VK7JG-NPHTM-C97JM-9MPGT-3V66T",
        "Windows 11 Home": "YTMG3-N6DKC-DKB77-7M9GH-8HVX7",
        "Windows 11 Home Single Language": "BT79Q-G7N6G-PGBYW-4YWX6-6F4BT",
    ]
    var effectiveKey: String? { productKey ?? Self.genericKeys[edition] }

    public func validate() -> [String] {
        var problems: [String] = []
        let nameOK = computerName.range(of: "^[A-Za-z0-9-]{1,15}$", options: .regularExpression) != nil
        if !nameOK { problems.append("Computer name must be 1–15 letters, digits or hyphens.") }
        if userName.isEmpty || userName.count > 20 || userName.contains(where: { "\"/\\[]:;|=,+*?<>@".contains($0) }) {
            problems.append("User name must be 1–20 characters without \" / \\ [ ] : ; | = , + * ? < > @.")
        }
        if ["administrator", "guest", "system"].contains(userName.lowercased()) { problems.append("That user name is reserved by Windows.") }
        // XML 1.0 cannot carry control characters at all, not even as &#1;: the answer file would not load.
        let unrepresentable = SystemAccount.hasUnsupportedCharacters
        if unrepresentable(userName) { problems.append("User name must not contain control characters or invisible characters.") }
        // A name of spaces reads back as no name, and Windows trims spaces at the ends (fuzz tests).
        if userName != userName.trimmingCharacters(in: .whitespaces) || userName.allSatisfy({ $0 == "." }) {
            problems.append("User name must not start or end with a space, or be only dots.")
        }
        if unrepresentable(password) { problems.append("Password must not contain control characters or invisible characters.") }
        // XML readers drop text that is only white space, so such a password would arrive empty (fuzz tests).
        if !password.isEmpty, password.allSatisfy(\.isWhitespace) { problems.append("Password must not be only spaces.") }
        if [locale, timeZone, edition, productKey ?? ""].contains(where: unrepresentable) {
            problems.append("Language, time zone, edition and product key must not contain control characters.")
        }
        return problems
    }
}

public enum AutounattendBuilder {
    /// Volume label of the unattended-install media. The first-logon script finds the media by it.
    public static let mediaLabel = "TANDEMSETUP"
    /// Drive letters probed for the driver folder during setup (the media's letter is not known in advance).
    static let probedDriveLetters = ["D", "E", "F", "G", "H", "I"]

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static let componentAttributes =
        #"processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State""#

    public static func xml(_ o: WindowsUnattendOptions) throws -> String {
        let problems = o.validate()
        guard problems.isEmpty else { throw VMError("The Windows setup answers are not valid.", detail: problems.joined(separator: "\n")) }
        let e = escape
        let driverPaths = probedDriveLetters.enumerated().map { i, letter in
            "        <PathAndCredentials wcm:action=\"add\" wcm:keyValue=\"\(i + 1)\"><Path>\(letter):\\drivers</Path></PathAndCredentials>"
        }.joined(separator: "\n")
        let bypass = o.bypassSecureBootCheck ? """
              <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                  <Order>1</Order>
                  <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
              </RunSynchronous>

        """ : ""
        let key = o.effectiveKey.map { "\n          <ProductKey><Key>\(e($0))</Key><WillShowUI>OnError</WillShowUI></ProductKey>" } ?? ""
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">
          <settings pass="windowsPE">
            <component name="Microsoft-Windows-International-Core-WinPE" \(componentAttributes)>
              <SetupUILanguage><UILanguage>\(e(o.locale))</UILanguage></SetupUILanguage>
              <InputLocale>\(e(o.locale))</InputLocale>
              <SystemLocale>\(e(o.locale))</SystemLocale>
              <UILanguage>\(e(o.locale))</UILanguage>
              <UserLocale>\(e(o.locale))</UserLocale>
            </component>
            <component name="Microsoft-Windows-PnpCustomizationsWinPE" \(componentAttributes)>
              <DriverPaths>
        \(driverPaths)
              </DriverPaths>
            </component>
            <component name="Microsoft-Windows-Setup" \(componentAttributes)>
        \(bypass)      <DiskConfiguration>
                <Disk wcm:action="add">
                  <DiskID>0</DiskID>
                  <WillWipeDisk>true</WillWipeDisk>
                  <CreatePartitions>
                    <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>260</Size></CreatePartition>
                    <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
                    <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
                  </CreatePartitions>
                  <ModifyPartitions>
                    <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
                    <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
                  </ModifyPartitions>
                </Disk>
              </DiskConfiguration>
              <ImageInstall>
                <OSImage>
                  <InstallFrom>
                    <MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>\(e(o.edition))</Value></MetaData>
                  </InstallFrom>
                  <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
                </OSImage>
              </ImageInstall>
              <UserData>
                <AcceptEula>true</AcceptEula>\(key)
              </UserData>
            </component>
          </settings>
          <settings pass="offlineServicing">
            <component name="Microsoft-Windows-PnpCustomizationsNonWinPE" \(componentAttributes)>
              <DriverPaths>
        \(driverPaths)
              </DriverPaths>
            </component>
          </settings>
          <settings pass="specialize">
            <component name="Microsoft-Windows-Deployment" \(componentAttributes)>
              <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                  <Order>1</Order>
                  <Description>Allow setup to finish without a Microsoft account</Description>
                  <Path>reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
              </RunSynchronous>
            </component>
            <component name="Microsoft-Windows-Shell-Setup" \(componentAttributes)>
              <ComputerName>\(e(o.computerName))</ComputerName>
              <TimeZone>\(e(o.timeZone))</TimeZone>
            </component>
          </settings>
          <settings pass="oobeSystem">
            <component name="Microsoft-Windows-International-Core" \(componentAttributes)>
              <InputLocale>\(e(o.locale))</InputLocale>
              <SystemLocale>\(e(o.locale))</SystemLocale>
              <UILanguage>\(e(o.locale))</UILanguage>
              <UserLocale>\(e(o.locale))</UserLocale>
            </component>
            <component name="Microsoft-Windows-Shell-Setup" \(componentAttributes)>
              <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
              </OOBE>
              <UserAccounts>
                <LocalAccounts>
                  <LocalAccount wcm:action="add">
                    <Name>\(e(o.userName))</Name>
                    <Group>Administrators</Group>
                    <Password><Value>\(e(o.password))</Value><PlainText>true</PlainText></Password>
                  </LocalAccount>
                </LocalAccounts>
              </UserAccounts>
              <AutoLogon>
                <Enabled>true</Enabled>
                <LogonCount>1</LogonCount>
                <Username>\(e(o.userName))</Username>
                <Password><Value>\(e(o.password))</Value><PlainText>true</PlainText></Password>
              </AutoLogon>
              <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                  <Order>1</Order>
                  <Description>Install drivers and the guest agent</Description>
                  <CommandLine>cmd /c "for %i in (D E F G H I J K L) do @if exist %i:\\firstlogon.ps1 powershell -NoProfile -ExecutionPolicy Bypass -File %i:\\firstlogon.ps1"</CommandLine>
                </SynchronousCommand>
              </FirstLogonCommands>
            </component>
          </settings>
        </unattend>

        """
    }

    /// PowerShell single-quoted string literal. PowerShell also takes the typographic single quotes
    /// (‘ ’ ‚ ‛) as quote marks, which a Mac keyboard types by itself: each is doubled like ', or a
    /// password with ’ in it would end the string early and the rest would run as script.
    static func psQuoted(_ s: String) -> String {
        var out = "'"
        for c in s.unicodeScalars {
            out.unicodeScalars.append(c)
            if psQuoteMarks.contains(c) { out.unicodeScalars.append(c) }
        }
        return out + "'"
    }
    static let psQuoteMarks: Set<Unicode.Scalar> = ["'", "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}"]

    /// The first-logon script for these answers: the common part, then automatic sign-in at every start
    /// when asked for. The answer file's own AutoLogon covers only the first sign-in (it is what runs this
    /// script); without this part later starts stop at the lock screen.
    public static func firstLogonScript(for o: WindowsUnattendOptions) -> String {
        guard o.autoLogin else { return firstLogonScript }
        return firstLogonScript.replacingOccurrences(of: "\nStop-Transcript | Out-Null", with: """

        # 3. Sign the account in by itself at every start, as Tandem's Create New asked for.
        $winlogon = 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon'
        Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '1'
        Set-ItemProperty -Path $winlogon -Name DefaultUserName -Value \(psQuoted(o.userName))
        Set-ItemProperty -Path $winlogon -Name DefaultDomainName -Value $env:COMPUTERNAME
        Set-ItemProperty -Path $winlogon -Name DefaultPassword -Value \(psQuoted(o.password))
        Remove-ItemProperty -Path $winlogon -Name AutoLogonCount -ErrorAction SilentlyContinue
        # Windows 11 hides automatic sign-in behind "require Windows Hello"; switch that off for this account.
        New-Item -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\PasswordLess\\Device' -Force | Out-Null
        Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\PasswordLess\\Device' -Name DevicePasswordLessBuildVersion -Value 0 -Type DWord

        Stop-Transcript | Out-Null
        """)
    }

    /// Runs once at first logon from the install media: drivers, then the guest agent.
    public static let firstLogonScript = #"""
    # Tandem first-logon script: device drivers, then the guest agent. Run in a guest on 2026-11-14.
    $ErrorActionPreference = 'Continue'
    $media = Split-Path -Qualifier $PSCommandPath
    $log = "$env:SystemDrive\tandem-firstlogon.log"
    Start-Transcript -Path $log -Append | Out-Null

    # 1. Device drivers (network, virtio-serial for the guest agent, display). Setup has already put
    #    them in the driver store; this installs them on any device that is still without one.
    if (Test-Path "$media\drivers") {
        pnputil /add-driver "$media\drivers\*.inf" /subdirs /install
    } else {
        Write-Output 'No drivers folder on the install media.'
    }

    # 2. Guest agent. It must run inside the user's session (clipboard, display), so it starts at logon
    #    as a scheduled task, not as a service.
    $agentSource = "$media\tandem-agent.exe"
    if (Test-Path $agentSource) {
        $dir = "$env:ProgramFiles\Tandem"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Copy-Item $agentSource "$dir\tandem-agent.exe" -Force
        Copy-Item "$media\tandem-agent-task.xml" "$dir\tandem-agent-task.xml" -Force
        schtasks /Create /F /TN 'Tandem Guest Agent' /XML "$dir\tandem-agent-task.xml"
        schtasks /Run /TN 'Tandem Guest Agent'
    } else {
        Write-Output 'No guest agent on the install media.'
    }

    Stop-Transcript | Out-Null
    """#
}
