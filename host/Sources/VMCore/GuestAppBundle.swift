import CoreGraphics
import Foundation
import ImageIO

/// A small Mac app that stands in the Dock for one program of a guest while its windows are shown as
/// Mac windows (Seamless Mode). Tandem writes one per program, with the program's name and icon, starts
/// it while the program has windows, and tells it to quit when it has none.
///
/// The stand-in owns no windows: the guest's windows belong to Tandem. Clicking the stand-in's Dock tile
/// asks Tandem to bring the program's front window forward; while that window is in use, Tandem is the
/// active app and its name is in the menu bar. That is a known limit of this arrangement.
public enum GuestAppBundle {
    /// File name of the stand-in's program, inside Tandem.app's Resources and inside every written bundle.
    public static let executableName = "TandemGuestApp"
    /// Posted by a stand-in when the user chooses it (Dock click, Command-Tab). `userInfo`: "vm", "program".
    public static let activateNotification = TandemIdentity.guestApp + ".activate"
    /// Posted by a stand-in when the user quits it: Tandem closes the program's windows. Same `userInfo`.
    public static let closeNotification = TandemIdentity.guestApp + ".close"
    /// Posted by Tandem; the stand-in whose bundle identifier is the notification's object quits.
    public static let quitNotification = TandemIdentity.guestApp + ".quit"
    /// Info.plist keys that tell a stand-in which VM and program it stands for.
    public static let vmKey = "TandemVM"
    public static let programKey = "TandemProgram"

    /// Where the stand-ins of one VM are kept.
    public static func directory(root: URL, vmName: String) -> URL {
        root.appendingPathComponent("Guest Apps", isDirectory: true).appendingPathComponent(fileName(vmName), isDirectory: true)
    }

    /// A name that is safe as one path component.
    public static func fileName(_ name: String) -> String {
        let cleaned = String(name.map { "/:\\\0".contains($0) || $0.isNewline ? "-" : $0 }).trimmingCharacters(in: .whitespaces)
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? "Program" : String(trimmed.prefix(80))
    }

    /// Stable per VM and program, and distinct between them (FNV-1a over both).
    public static func bundleIdentifier(vm: UUID, program: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in Array(vm.uuidString.utf8) + [0] + Array(program.lowercased().utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return TandemIdentity.guestApp + "." + String(hash, radix: 16)
    }

    private static func png(_ image: CGImage, side: Int) -> Data? {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let scaled = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// An icon file (.icns) holding the picture at 128 and 256 pixels.
    public static func icns(from image: CGImage) -> Data? {
        var body = Data()
        for (type, side) in [("ic07", 128), ("ic08", 256)] {
            guard let picture = png(image, side: side) else { return nil }
            body.append(Data(type.utf8))
            withUnsafeBytes(of: UInt32(picture.count + 8).bigEndian) { body.append(contentsOf: $0) }
            body.append(picture)
        }
        var file = Data("icns".utf8)
        withUnsafeBytes(of: UInt32(body.count + 8).bigEndian) { file.append(contentsOf: $0) }
        file.append(body)
        return file
    }

    // MARK: Launchers: stand-ins the user keeps
    //
    // A launcher is the same small app, kept where the Mac looks for apps, so the user can pin it to the
    // Dock, find it with Spotlight and choose it under Finder's Open With. Opened while its VM is stopped
    // or suspended (or while Tandem is not running at all), it leaves a launch request for Tandem and
    // starts Tandem if need be; Tandem starts or resumes the VM and opens the program and documents.

    /// Posted by a launcher after it has left a launch request, for a Tandem that is already running.
    public static let launchNotification = TandemIdentity.guestApp + ".launch"
    /// Info.plist keys of a launcher: Tandem.app's location, the VM library it belongs to (absent for
    /// the default one), and the program's name.
    public static let hostKey = "TandemHost"
    public static let libraryKey = "TandemLibrary"
    public static let launcherKey = "TandemLauncher"
    /// Tandem.app's bundle identifier (scripts/build-app.sh), for finding it when it has been moved.
    public static let hostBundleIdentifier = TandemIdentity.app
    public static let targetKey = "TandemTarget"

    /// What a launcher needs to find its way back to Tandem.
    public struct Launcher: Equatable, Sendable {
        /// Tandem.app, which the launcher starts when it is not running.
        public var host: URL
        /// The VM library's root, when it is not the default one (a test library).
        public var library: URL?
        /// File name extensions the program opens, with or without the leading dot.
        public var documentExtensions: [String]
        /// The program's file in the guest, when it has one (not a store app). Its file name tells
        /// which of the guest's windows belong to the program.
        public var target: String?
        public init(host: URL, library: URL? = nil, documentExtensions: [String] = [], target: String? = nil) {
            self.host = host; self.library = library; self.documentExtensions = documentExtensions; self.target = target
        }
    }

    /// A launch request, as a launcher leaves it in the library's `Launch Requests` folder.
    public struct LaunchRequest: Codable, Equatable, Sendable {
        public var vm: UUID
        /// The program's key: "program:<id>".
        public var program: String
        public var name: String
        /// Mac paths of the documents to open; empty to just start the program.
        public var documents: [String]
        public var created: Date
        public init(vm: UUID, program: String, name: String, documents: [String], created: Date = Date()) {
            self.vm = vm; self.program = program; self.name = name; self.documents = documents; self.created = created
        }
        /// A request nobody picked up in time is not carried out late.
        public static let lifetime: TimeInterval = 120
        public var isFresh: Bool { abs(created.timeIntervalSinceNow) < Self.lifetime }
    }

    public static func requestsDirectory(root: URL) -> URL { root.appendingPathComponent("Launch Requests", isDirectory: true) }

    /// Leaves a request for Tandem. Returns the file written.
    @discardableResult
    public static func leave(_ request: LaunchRequest, root: URL) throws -> URL {
        let directory = requestsDirectory(root: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString + ".json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(request).write(to: url, options: .atomic)
        return url
    }

    /// Takes every waiting request out of the folder, oldest first. Stale and unreadable ones are dropped.
    public static func collect(root: URL) -> [LaunchRequest] {
        let fm = FileManager.default
        let directory = requestsDirectory(root: root)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var requests: [LaunchRequest] = []
        for url in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
            defer { try? fm.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url), let request = try? decoder.decode(LaunchRequest.self, from: data), request.isFresh else { continue }
            requests.append(request)
        }
        return requests.sorted { $0.created < $1.created }
    }

    /// Extensions as an Info.plist wants them: lower case, no dot, no duplicates, nothing odd.
    public static func documentExtensions(_ extensions: [String]) -> [String] {
        var seen = Set<String>()
        return extensions.compactMap { raw in
            let ext = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            guard !ext.isEmpty, ext.count <= 15, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-+".contains($0)) }),
                  seen.insert(ext).inserted else { return nil }
            return ext
        }
    }

    /// Writes (or rewrites) the stand-in for one program and returns its location.
    /// `stub` is the stand-in's program file, copied in as is. With `launcher`, the result is a launcher:
    /// it knows where Tandem is and offers itself for the program's document types.
    public static func write(in directory: URL, name: String, vm: UUID, program: String, icon: CGImage?, stub: URL,
                             launcher: Launcher? = nil) throws -> URL {
        let fm = FileManager.default
        let bundle = directory.appendingPathComponent(fileName(name) + ".app", isDirectory: true)
        try? fm.removeItem(at: bundle)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try fm.copyItem(at: stub, to: contents.appendingPathComponent("MacOS").appendingPathComponent(executableName))
        var info: [String: Any] = [
            "CFBundleExecutable": executableName,
            "CFBundleIdentifier": bundleIdentifier(vm: vm, program: program),
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "15.0",
            "LSMultipleInstancesProhibited": true,
            "NSHighResolutionCapable": true,
            "NSPrincipalClass": "NSApplication",
            vmKey: vm.uuidString,
            programKey: program,
        ]
        if let launcher {
            info[launcherKey] = true
            info[hostKey] = launcher.host.path
            if let library = launcher.library { info[libraryKey] = library.path }
            if let target = launcher.target, !target.isEmpty { info[targetKey] = target }
            let extensions = documentExtensions(launcher.documentExtensions)
            if !extensions.isEmpty {
                // "Alternate": offered under Open With, never made the default program for a file type.
                info["CFBundleDocumentTypes"] = [[
                    "CFBundleTypeName": "\(name) document",
                    "CFBundleTypeRole": "Editor",
                    "LSHandlerRank": "Alternate",
                    "CFBundleTypeExtensions": extensions,
                ]]
            } else {
                // The guest named no file types for this program. It still takes any file dropped on its
                // icon or sent with `open -a`; rank "None" keeps it out of every Open With menu.
                info["CFBundleDocumentTypes"] = [[
                    "CFBundleTypeName": "Document",
                    "CFBundleTypeRole": "Viewer",
                    "LSHandlerRank": "None",
                    "LSItemContentTypes": ["public.data"],
                ]]
            }
        }
        if let icon, let data = icns(from: icon) {
            try data.write(to: contents.appendingPathComponent("Resources/icon.icns"))
            info["CFBundleIconFile"] = "icon.icns"
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        return bundle
    }
}
