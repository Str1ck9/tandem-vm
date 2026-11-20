import Foundation
import Virtualization
import VMCore

/// The engine-specific parts of cloning a VM (VMCore/Clone.swift), for the app and vmctl.
public enum CloneSupport {
    /// `qemuImg`: Tandem's qemu-img, needed only for VMs whose disk has a backing file.
    public static func hooks(qemuImg: URL?) -> CloneHooks {
        CloneHooks(
            rebaseDisk: { disk, backing, format in
                guard let qemuImg else {
                    throw VMError("QEMU is needed to clone this VM.", detail: "Its disk is layered on a base disk, and qemu-img updates the layer.")
                }
                // -u: only the header changes; the base file itself is the same data, cloned.
                let result = try ToolRun.run(qemuImg, ["rebase", "-u", "-F", format, "-b", backing, disk.path],
                                             timeout: ToolRun.Limit.image, output: .discard)
                guard result.succeeded else {
                    throw ToolRun.failed(result, "The clone's disk could not be pointed at its own base disk.")
                }
            },
            renewVZMachineIdentifier: { bundle in
                try VZMacMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifierURL, options: .atomic)
            })
    }
}
