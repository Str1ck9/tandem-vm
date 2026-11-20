import AppKit
import VMCore

/// Actions > Install Tandem Tools… for macOS guests. The tools come on a disc ("Tandem Tools") that
/// Apple's framework can only attach when the VM starts, so a running VM that started without it needs
/// a restart first (GuestToolsMacOS.swift).
extension VMSession {
    var canInstallMacOSTools: Bool {
        config.guestOS == .macos && config.engine == .vz && GuestTools.macOSAgent != nil && busy == nil && provisioning == nil
    }

    /// The tools have answered from this guest at least once.
    var hasMacOSTools: Bool { config.guestOS == .macos && config.guestTools.installedVersion != nil }

    func installMacOSTools() {
        guard canInstallMacOSTools else { return }
        // Attached at this start already: show where it is.
        let attachedNow = state.isActive && GuestTools.attachesMacOSDisc(config)
        bundle.config.guestTools.toolsDiscRequested = Date()
        do { try bundle.save() } catch { errorMessage = error.userFacingText; return }

        let alert = NSAlert()
        alert.messageText = hasMacOSTools ? "Reinstall Tandem Tools in “\(config.name)”" : "Install Tandem Tools in “\(config.name)”"
        let steps = "In the VM, open the “\(GuestTools.macOSVolumeName)” disc in the Finder and double-click “\(GuestTools.macOSPackageName)”. It asks for an administrator's password."
        if attachedNow {
            alert.informativeText = steps
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } else if state.isActive {
            alert.informativeText = "The tools disc can only be attached when the VM starts. Shut the VM down and start it again; then: \(steps)"
            alert.addButton(withTitle: "Shut Down")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn { stop() }
        } else {
            alert.informativeText = "The tools disc is attached when the VM starts. Then: \(steps)"
            alert.addButton(withTitle: can(.start) ? "Start" : "OK")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn, can(.start) { start() }
        }
    }
}
