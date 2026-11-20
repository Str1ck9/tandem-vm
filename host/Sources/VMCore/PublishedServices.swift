import Foundation

// Guest services published to the Mac under a stable local name.
//
// A service inside a VM (a web server on port 8080, say) is given a fixed port on the Mac and the
// name `<vm>.tandem.test`. The name and port stay the same when the guest gets another address or is
// restarted, because the Mac side listens itself and passes each connection on to wherever the guest
// is at that moment (`ServicePublisher` in the Sharing module does that part).

public struct PublishedService: Codable, Equatable, Sendable, Identifiable {
    public enum Scope: String, Codable, Sendable, CaseIterable {
        /// Reachable from this Mac only: the Mac listens on 127.0.0.1.
        case mac
        /// Reachable from other devices on the Mac's network as well: the Mac listens on every interface.
        case lan

        public var label: String { self == .mac ? "This Mac only" : "This Mac and the local network" }
        public var bindAddress: String { self == .mac ? "127.0.0.1" : "0.0.0.0" }
    }

    /// A short label of the user's, unique within the VM: "web", "postgres".
    public var name: String
    public var guestPort: Int
    /// The port on the Mac. Chosen once when the service is published, then kept, so the address is stable.
    public var hostPort: Int
    public var scope: Scope

    public var id: String { name }

    public init(name: String, guestPort: Int, hostPort: Int, scope: Scope = .mac) {
        self.name = name; self.guestPort = guestPort; self.hostPort = hostPort; self.scope = scope
    }
}

public enum PublishedServices {
    /// The domain all published names live under. `.test` is reserved for this kind of use and never
    /// exists on the Internet.
    public static let domain = "tandem.test"

    /// The VM's host name: its name in lower case, with everything but letters and digits turned into hyphens.
    public static func hostLabel(forVMNamed name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let mapped = folded.unicodeScalars.map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? Character($0) : "-" }
        let label = String(mapped).split(separator: "-").joined(separator: "-")
        return String((label.isEmpty ? "vm" : label).prefix(63)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// `my-linux.tandem.test`: resolves on this Mac once local names are switched on (one admin command).
    public static func hostName(forVMNamed name: String) -> String { hostLabel(forVMNamed: name) + "." + domain }

    /// `my-linux.localhost`: browsers and curl treat every name under `localhost` as this Mac, with no setup.
    public static func loopbackName(forVMNamed name: String) -> String { hostLabel(forVMNamed: name) + ".localhost" }

    /// The single place that says whether a VM may publish services at all: its sharing profile must
    /// allow connections into it (`SharingPolicy`, the one decision point for everything a VM shares).
    public static func publishingAllowed(for config: VMConfig) -> Bool { SharingPolicy(config).allowsInboundServices }

    public static func validate(name: String, guestPort: Int, hostPort: Int?) -> [String] {
        var problems: [String] = []
        if name.isEmpty || name.count > 40 || name.contains(where: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) {
            problems.append("The service name must be 1 to 40 letters, digits, hyphens or underscores.")
        }
        if !(1...65535).contains(guestPort) { problems.append("The guest port must be between 1 and 65535.") }
        if let hostPort, !(1024...65535).contains(hostPort) {
            problems.append("The port on the Mac must be between 1024 and 65535; lower ports need administrator rights.")
        }
        return problems
    }

    /// Chooses the Mac port for a new service: the wanted one, or the guest's own port number when that
    /// is free, or the next free one from 20000 up. `taken` are ports other published services already
    /// have (in any VM); `isFree` asks the system whether a port can be listened on right now.
    public static func choosePort(wanted: Int?, guestPort: Int, taken: Set<Int>, isFree: (Int) -> Bool) throws -> Int {
        if let wanted {
            if taken.contains(wanted) { throw VMError("Port \(wanted) on the Mac is already used by another published service.") }
            if !isFree(wanted) { throw VMError("Port \(wanted) on the Mac is in use by another program.", detail: "Choose another port, or leave it out and Tandem picks a free one.") }
            return wanted
        }
        if guestPort >= 1024, !taken.contains(guestPort), isFree(guestPort) { return guestPort }
        for port in 20000..<30000 where !taken.contains(port) && isFree(port) { return port }
        throw VMError("No free port was found on the Mac.")
    }

    /// Adds a service to a VM's configuration, or replaces the one of the same name.
    public static func publish(name: String, guestPort: Int, hostPort: Int?, scope: PublishedService.Scope,
                               in config: inout VMConfig, takenElsewhere: Set<Int>, isFree: (Int) -> Bool) throws -> PublishedService {
        try SharingPolicy(config).requireInboundServices()
        let problems = validate(name: name, guestPort: guestPort, hostPort: hostPort)
        guard problems.isEmpty else { throw VMError("The service cannot be published.", detail: problems.joined(separator: "\n")) }
        var services = config.publishedServices ?? []
        let existing = services.first { $0.name == name }
        // Republishing under the same name keeps its port unless another is asked for.
        let keep = existing.flatMap { hostPort == nil || hostPort == $0.hostPort ? $0.hostPort : nil }
        let taken = takenElsewhere.union(services.filter { $0.name != name }.map(\.hostPort))
        let port = try keep ?? choosePort(wanted: hostPort, guestPort: guestPort, taken: taken, isFree: isFree)
        let service = PublishedService(name: name, guestPort: guestPort, hostPort: port, scope: scope)
        services.removeAll { $0.name == name }
        services.append(service)
        config.publishedServices = services
        return service
    }

    @discardableResult
    public static func unpublish(name: String, in config: inout VMConfig) -> Bool {
        guard var services = config.publishedServices, services.contains(where: { $0.name == name }) else { return false }
        services.removeAll { $0.name == name }
        config.publishedServices = services.isEmpty ? nil : services
        return true
    }
}
