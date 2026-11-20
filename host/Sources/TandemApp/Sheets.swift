import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VMCore

private let hostCPUs = ProcessInfo.processInfo.processorCount
private let hostMemoryMiB = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)

/// CPU, memory and disk controls shared by the wizard and the settings sheet.
struct HardwareFields: View {
    @Binding var cpuCount: Int
    @Binding var memoryMiB: Int
    @Binding var diskGiB: Int
    var minimumDiskGiB: Int = 1

    var body: some View {
        Stepper("Processors: \(cpuCount)", value: $cpuCount, in: 1...hostCPUs)
        Stepper("Memory: \(memoryMiB / 1024) GiB", value: $memoryMiB, in: 1024...max(1024, hostMemoryMiB - 2048), step: 1024)
        Stepper("Disk: \(diskGiB) GiB", value: $diskGiB, in: minimumDiskGiB...2048, step: 8)
    }
}
