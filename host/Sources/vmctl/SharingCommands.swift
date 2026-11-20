import Foundation
import Sharing
import VMCore

// `vmctl sharing`, `vmctl share`, `vmctl unshare`: the same changes the settings panel makes, through the
// same calls (`SharingStore`), so the app and the command line cannot disagree about what a VM shares.

private func onOff(_ args: Args, _ name: String) -> Bool? {
    guard let value = args.options[name] else { return nil }
    switch value.lowercased() {
    case "on", "yes", "true", "allow", "allowed": return true
    case "off", "no", "false", "block", "blocked": return false
    default: fail("--\(name) must be on or off")
    }
}

private func clipboardChoice(_ text: String) -> ClipboardSharing {
    switch text.lowercased() {
    case "off", "none": return .off
    case "to-guest", "mac-to-guest": return .macToGuest
    case "to-mac", "guest-to-mac": return .guestToMac
    case "both", "on": return .both
    default: fail("--clipboard must be off, to-guest, to-mac or both")
    }
}

private func printPolicy(_ bundle: VMBundle, json: Bool) {
    let running = TemporarySharingFile.hasLiveOwner(bundle)
    let policy = SharingPolicy(bundle.config, temporary: running ? TemporarySharingFile.load(bundle) : TemporaryGrants())
    if json {
        struct Report: Encodable {
            struct Folder: Encodable { var name: String; var hostPath: String; var readOnly: Bool; var temporary: Bool }
            var running: Bool
            var folders: [Folder]
            var clipboard: ClipboardSharing
            var usb: Bool
            var network: NetworkExposure
            var preset: String?
            var notes: [String]
        }
        let report = Report(running: running,
                            folders: policy.folders.map { .init(name: $0.name, hostPath: $0.folder.hostPath, readOnly: $0.folder.readOnly, temporary: $0.temporary) },
                            clipboard: policy.clipboard, usb: policy.usbAllowed, network: policy.network,
                            preset: policy.temporary.isEmpty ? policy.profile.preset?.rawValue : nil,
                            notes: policy.networkNotes(for: bundle.config.network))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try! encoder.encode(report), as: UTF8.self))
        return
    }
    print("Sharing for “\(bundle.config.name)”\(running ? " (running)" : ""):")
    for line in policy.summary(network: bundle.config.network) { print("  " + line) }
}

/// vmctl sharing <vm> [--preset restricted|default] [--clipboard …] [--usb on|off] [--outbound on|off]
///                    [--inbound on|off] [--bridged on|off] [--temporary] [--json]
func cmdSharing(_ args: Args) throws {
    guard let key = args.positional.first else { fail("sharing needs a VM") }
    let bundle = try openLibrary().find(key)
    var profile = bundle.config.sharing
    if let name = args.options["preset"] {
        guard let preset = SharingProfile.Preset(rawValue: name) else { fail("--preset must be restricted or default") }
        // A preset replaces everything, the folder list included: "default" shares nothing either.
        profile = preset.profile
    }
    let temporary = args.flags.contains("temporary")
    let clipboard = args.options["clipboard"].map(clipboardChoice)
    let usb = onOff(args, "usb")
    if temporary {
        guard args.options["preset"] == nil, onOff(args, "outbound") == nil, onOff(args, "inbound") == nil, onOff(args, "bridged") == nil else {
            fail("--temporary applies to --clipboard and --usb only; network settings and presets are permanent")
        }
        if clipboard != nil || usb != nil {
            try SharingStore.setTemporary(clipboard: clipboard.map { .some($0) }, usb: usb.map { .some($0) }, bundleURL: bundle.url)
        }
    } else {
        if let clipboard { profile.clipboard = clipboard }
        if let usb { profile.usb = usb }
        if let value = onOff(args, "outbound") { profile.network.outbound = value }
        if let value = onOff(args, "inbound") { profile.network.inbound = value }
        if let value = onOff(args, "bridged") { profile.network.bridged = value }
        if profile != bundle.config.sharing {
            let before = bundle.config.sharing.network
            try SharingStore.setProfile(profile, bundleURL: bundle.url)
            if profile.network != before && TemporarySharingFile.hasLiveOwner(bundle) {
                if before.inbound && !profile.network.inbound { print("Connections into the virtual machine are closed now.") }
                var later = before; later.inbound = profile.network.inbound && before.inbound
                if later != profile.network { print("The other network changes take effect when the virtual machine is restarted.") }
            }
        }
    }
    printPolicy(try VMBundle.load(from: bundle.url), json: args.flags.contains("json"))
}

/// vmctl share <vm> <folder> [--name N] [--read-only] [--temporary]
func cmdShare(_ args: Args) throws {
    guard args.positional.count == 2 else { fail("share needs a VM and a folder") }
    let bundle = try openLibrary().find(args.positional[0])
    let temporary = args.flags.contains("temporary")
    let running = TemporarySharingFile.hasLiveOwner(bundle)
    if running && SharedFolderService.kind(for: bundle.config) == "9p" {
        if temporary { fail("“\(bundle.config.name)” gets its folders as devices when it starts, so a folder cannot be added while it runs.") }
        print("“\(bundle.config.name)” gets its folders as devices when it starts; the folder appears after a restart.")
    }
    let folder = try SharingStore.share(path: args.positional[1], name: args.options["name"], readOnly: args.flags.contains("read-only"),
                                        temporary: temporary, bundleURL: bundle.url)
    print("Shared \(folder.hostPath) as “\(folder.name)” (\(folder.readOnly ? "read-only" : "read/write")\(temporary ? ", until shutdown" : "")).")
}

/// vmctl unshare <vm> <folder name or path>
func cmdUnshare(_ args: Args) throws {
    guard args.positional.count == 2 else { fail("unshare needs a VM and a folder name or path") }
    let bundle = try openLibrary().find(args.positional[0])
    let removed = try SharingStore.unshare(args.positional[1], bundleURL: bundle.url)
    guard removed > 0 else { fail("“\(args.positional[1])” is not shared with “\(bundle.config.name)”.") }
    print("Stopped sharing “\(args.positional[1])”.")
}
