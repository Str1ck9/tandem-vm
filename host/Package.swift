// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tandem",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VMCore", targets: ["VMCore"]),
        .library(name: "GuestLink", targets: ["GuestLink"]),
        .library(name: "EngineVZ", targets: ["EngineVZ"]),
        .library(name: "EngineQEMU", targets: ["EngineQEMU"]),
        .library(name: "Provisioning", targets: ["Provisioning"]),
        .executable(name: "vmctl", targets: ["vmctl"]),
        .executable(name: "TandemGuestApp", targets: ["TandemGuestApp"]),
        .executable(name: "tandem", targets: ["tandem"]),
        .executable(name: "tandem-release", targets: ["tandem-release"]),
    ],
    targets: [
        // The identifiers derived from the build's bundle prefix; no dependencies, so the root helper can use it.
        .target(name: "IdentityCore"),
        .target(name: "VMCore", dependencies: ["IdentityCore"]),
        .target(name: "GuestLink", dependencies: ["VMCore"]),
        .target(name: "EngineVZ", dependencies: ["VMCore", "GuestLink", "NetHelperClient", "Provisioning"]),
        .target(name: "EngineQEMU", dependencies: ["VMCore", "GuestLink", "NetHelperClient"]),
        .target(name: "Provisioning", dependencies: ["VMCore"]),
        .target(name: "Sharing", dependencies: ["VMCore"]),
        .target(name: "Migration", dependencies: ["VMCore", "Provisioning", "EngineQEMU"]),
        .target(name: "NetHelperClient", dependencies: ["VMCore"]),
        // Tandem's own updates: feed, Ed25519 signatures, download, install (no AppKit).
        .target(name: "Updater", dependencies: ["VMCore"]),
        .executableTarget(name: "tandem-release", dependencies: ["Updater", "VMCore"]),
        .executableTarget(name: "TandemNetHelper", dependencies: ["IdentityCore"]),
        .executableTarget(name: "TandemGuestApp", dependencies: ["VMCore"]),
        .executableTarget(name: "vmctl", dependencies: ["VMCore", "EngineVZ", "EngineQEMU", "GuestLink", "Provisioning", "Migration", "Sharing", "NetHelperClient"]),
        .executableTarget(name: "TandemApp", dependencies: ["VMCore", "EngineVZ", "EngineQEMU", "GuestLink", "Provisioning", "Migration", "Sharing", "NetHelperClient", "TandemControl", "Updater"]),
        // The control API's protocol, client and MCP server; no dependency on the engines.
        .target(name: "TandemControl", dependencies: ["IdentityCore"]),
        .executableTarget(name: "tandem", dependencies: ["TandemControl"]),
        // Seeded random input for the fuzz tests (Tests/FuzzSupport); not part of any product.
        .target(name: "FuzzSupport", path: "Tests/FuzzSupport"),
        .testTarget(name: "TandemControlTests", dependencies: ["TandemControl", "FuzzSupport"]),
        .testTarget(name: "VMCoreTests", dependencies: ["VMCore", "FuzzSupport"]),
        .testTarget(name: "EngineQEMUTests", dependencies: ["EngineQEMU", "VMCore", "NetHelperClient"]),
        .testTarget(name: "EngineVZTests", dependencies: ["EngineVZ", "Provisioning", "VMCore"]),
        .testTarget(name: "ProvisioningTests", dependencies: ["Provisioning", "VMCore", "FuzzSupport"]),
        .testTarget(name: "GuestLinkTests", dependencies: ["GuestLink", "VMCore", "FuzzSupport"]),
        .testTarget(name: "SharingTests", dependencies: ["Sharing", "VMCore", "FuzzSupport"]),
        .testTarget(name: "UpdaterTests", dependencies: ["Updater", "VMCore"]),
        .testTarget(name: "NetHelperTests", dependencies: ["NetHelperClient", "TandemNetHelper", "IdentityCore"]),
    ],
    swiftLanguageModes: [.v5]
)
