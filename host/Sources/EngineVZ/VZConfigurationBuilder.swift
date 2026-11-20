import Foundation
import Virtualization
import VMCore

/// Turns a `VMConfig` into a `VZVirtualMachineConfiguration`.
public enum VZConfigurationBuilder {
    /// `bridgeSocket` is a connected datagram socket to the network helper, required when the network is bridged.
    public static func build(for bundle: VMBundle, bridgeSocket: FileHandle? = nil) throws -> VZVirtualMachineConfiguration {
        let config = bundle.config
        guard config.engine == .vz else { throw VMError("“\(config.name)” is not a VZ virtual machine.") }
        guard config.guestOS != .windows11arm else { throw VMError("Windows guests run on the QEMU engine.") }
        let mac = config.guestOS == .macos

        let vz = VZVirtualMachineConfiguration()
        vz.cpuCount = min(max(config.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
                          VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        vz.memorySize = min(max(UInt64(config.memoryMiB) << 20, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                            VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        if mac {
            vz.platform = try macPlatform(bundle)
            vz.bootLoader = VZMacOSBootLoader()
            vz.graphicsDevices = [macGraphics(config.display)]
            vz.keyboards = [VZMacKeyboardConfiguration()]
            vz.pointingDevices = [VZMacTrackpadConfiguration()]
        } else {
            vz.platform = try genericPlatform(bundle)
            vz.bootLoader = try efiBootLoader(bundle)
            vz.graphicsDevices = [graphics(config.display)]
            vz.keyboards = [VZUSBKeyboardConfiguration()]
            vz.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }
        vz.storageDevices = try storage(bundle)
        // The sharing policy decides the network: no adapter at all when the VM may not use the network
        // (Apple's NAT cannot be restricted), and bridged only where the profile allows it.
        let policy = SharingPolicy(config)
        vz.networkDevices = policy.network.outbound ? [try network(policy.enforced(config.network), bridgeSocket: bridgeSocket)] : []
        vz.audioDevices = audio(config.soundOrDefault).map { [$0] } ?? []
        vz.serialPorts = [try serialConsole(bundle)]
        vz.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vz.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        vz.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        vz.directorySharingDevices = try sharedFolders(config)

        do { try vz.validate() }
        catch { throw VMError("The VM configuration is not valid.", detail: error.localizedDescription) }
        return vz
    }

    static func genericPlatform(_ bundle: VMBundle) throws -> VZGenericPlatformConfiguration {
        let platform = VZGenericPlatformConfiguration()
        let url = bundle.machineIdentifierURL
        if let data = try? Data(contentsOf: url), let id = VZGenericMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = id
        } else {
            let id = VZGenericMachineIdentifier()
            try id.dataRepresentation.write(to: url, options: .atomic)
            platform.machineIdentifier = id
        }
        return platform
    }

    /// A macOS guest is tied to three files made when it was installed: the hardware model, the machine
    /// identifier (ECID) and the auxiliary storage (its NVRAM). All three must be the ones it was installed with.
    static func macPlatform(_ bundle: VMBundle) throws -> VZMacPlatformConfiguration {
        func load(_ url: URL, _ what: String) throws -> Data {
            do { return try Data(contentsOf: url) }
            catch { throw VMError("The macOS VM is missing its \(what) (\(url.lastPathComponent)).", detail: "macOS installation is not built yet; only imported macOS VMs can run.") }
        }
        guard let model = VZMacHardwareModel(dataRepresentation: try load(bundle.hardwareModelURL, "hardware model")) else {
            throw VMError("The macOS VM's hardware model is not readable.")
        }
        guard model.isSupported else { throw VMError("This Mac cannot run the macOS VM's hardware model.") }
        guard let identifier = VZMacMachineIdentifier(dataRepresentation: try load(bundle.machineIdentifierURL, "machine identifier")) else {
            throw VMError("The macOS VM's machine identifier is not readable.")
        }
        guard FileManager.default.fileExists(atPath: bundle.auxiliaryStorageURL.path) else {
            throw VMError("The macOS VM is missing its auxiliary storage (\(bundle.auxiliaryStorageURL.lastPathComponent)).")
        }
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = model
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxiliaryStorageURL)
        return platform
    }

    static func macGraphics(_ display: DisplayConfig) -> VZMacGraphicsDeviceConfiguration {
        let device = VZMacGraphicsDeviceConfiguration()
        device.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: display.width, heightInPixels: display.height, pixelsPerInch: 80)]
        return device
    }

    static func efiBootLoader(_ bundle: VMBundle) throws -> VZEFIBootLoader {
        let loader = VZEFIBootLoader()
        let url = bundle.efiVarsURL
        loader.variableStore = FileManager.default.fileExists(atPath: url.path)
            ? VZEFIVariableStore(url: url)
            : try VZEFIVariableStore(creatingVariableStoreAt: url)
        return loader
    }

    static func storage(_ bundle: VMBundle) throws -> [VZStorageDeviceConfiguration] {
        var devices: [VZStorageDeviceConfiguration] = []
        for disk in bundle.config.disks {
            let url = try DiskPathRules.containedURL(disk.file, in: bundle.url)
            guard FileManager.default.fileExists(atPath: url.path) else { throw VMError("Disk image is missing: \(url.path)") }
            let attachment = try VZDiskImageStorageDeviceAttachment(url: url, readOnly: false)
            devices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
        }
        for media in bundle.config.removableMedia {
            let url = bundle.mediaURL(media)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw VMError("The disc image “\(url.lastPathComponent)” is missing.",
                              detail: "\(url.path)\nChoose it again, or remove it, under Configure > Hardware > CD/DVD.")
            }
            let attachment = try VZDiskImageStorageDeviceAttachment(url: url, readOnly: true)
            switch media.kind {
            case .installerISO:
                // USB mass storage is what EFI firmware boots installers from.
                devices.append(VZUSBMassStorageDeviceConfiguration(attachment: attachment))
            case .seedISO, .unattendDisk, .driverDisc:
                devices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
            }
        }
        // The Linux guest tools disc, when this host has a Linux agent build.
        if bundle.config.guestOS == .linux, let tools = try? GuestTools.linuxISO() {
            devices.append(VZUSBMassStorageDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: tools, readOnly: true)))
        }
        // The macOS guest tools disc, while one is asked for (GuestToolsMacOS.swift). The guest shows it
        // in the Finder as "Tandem Tools".
        if GuestTools.attachesMacOSDisc(bundle.config), let tools = try? GuestTools.macOSDisc() {
            devices.append(VZUSBMassStorageDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: tools, readOnly: true)))
        }
        return devices
    }

    /// Shared Mac folders as one virtiofs device. A macOS guest mounts it by itself (it appears in the
    /// Finder as "My Shared Files"); a Linux guest's agent mounts tag `tandem` at /media/mac.
    static func sharedFolders(_ config: VMConfig) throws -> [VZDirectorySharingDeviceConfiguration] {
        // A Linux guest always gets the device, empty if need be, so that a folder can be shared while it
        // runs (`VZEngine.updateSharedFolders`). A macOS guest would show an empty volume, so it gets the
        // device only when something is shared at start.
        guard !config.sharedFolders.isEmpty || config.guestOS == .linux else { return [] }
        let tag = config.guestOS == .macos ? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag : "tandem"
        let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
        device.share = try share(config.sharedFolders)
        return [device]
    }

    /// The folders as one share. Read-only folders are read-only on the host side: the guest cannot override it.
    static func share(_ folders: [SharedFolder]) throws -> VZMultipleDirectoryShare {
        var directories: [String: VZSharedDirectory] = [:]
        for folder in folders {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.hostPath, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw VMError("The shared folder “\(folder.name)” is missing: \(folder.hostPath)")
            }
            directories[folder.name] = VZSharedDirectory(url: URL(fileURLWithPath: folder.hostPath), readOnly: folder.readOnly)
        }
        return VZMultipleDirectoryShare(directories: directories)
    }

    static func network(_ net: NetworkConfig, bridgeSocket: FileHandle? = nil) throws -> VZVirtioNetworkDeviceConfiguration {
        let device = VZVirtioNetworkDeviceConfiguration()
        switch net.mode {
        case .nat:
            device.attachment = VZNATNetworkDeviceAttachment()
        case .bridged:
            // Apple's own bridged attachment needs a restricted entitlement; the helper's socket does not.
            guard let bridgeSocket else {
                throw VMError("Bridged networking needs the Tandem network helper.", detail: "Install it once with: sudo scripts/install-net-helper.sh")
            }
            device.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: bridgeSocket)
        }
        if let mac = VZMACAddress(string: net.mac) { device.macAddress = mac }
        return device
    }

    static func graphics(_ display: DisplayConfig) -> VZVirtioGraphicsDeviceConfiguration {
        let device = VZVirtioGraphicsDeviceConfiguration()
        device.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: display.width, heightInPixels: display.height)]
        return device
    }

    /// A sound card with the streams the VM's settings ask for, or none when both are off.
    static func audio(_ sound: SoundConfig) -> VZVirtioSoundDeviceConfiguration? {
        guard sound.output || sound.microphone else { return nil }
        let device = VZVirtioSoundDeviceConfiguration()
        var streams: [VZVirtioSoundDeviceStreamConfiguration] = []
        if sound.output {
            let output = VZVirtioSoundDeviceOutputStreamConfiguration()
            output.sink = VZHostAudioOutputStreamSink()
            streams.append(output)
        }
        if sound.microphone {
            // macOS asks for permission to use the microphone the first time.
            let input = VZVirtioSoundDeviceInputStreamConfiguration()
            input.source = VZHostAudioInputStreamSource()
            streams.append(input)
        }
        device.streams = streams
        return device
    }

    /// Guest serial console (hvc0) is written to `logs/console.log`.
    static func serialConsole(_ bundle: VMBundle) throws -> VZVirtioConsoleDeviceSerialPortConfiguration {
        try FileManager.default.createDirectory(at: bundle.logsDirectory, withIntermediateDirectories: true)
        let url = bundle.logsDirectory.appendingPathComponent("console.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let port = VZVirtioConsoleDeviceSerialPortConfiguration()
        port.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: handle)
        return port
    }
}
