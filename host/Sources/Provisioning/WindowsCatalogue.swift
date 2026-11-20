import Foundation
import VMCore

/// Microsoft's public list of Windows 11 install images.
///
/// Microsoft publishes a small cabinet file holding `products.xml`, the list its own Media Creation
/// Tool reads: every language and edition of the current Windows 11 release, each with the address,
/// size and SHA-1 of a compressed install image (an "ESD") on Microsoft's download servers.
/// The list comes over HTTPS; the images themselves are only offered over plain HTTP, which is why
/// each one is checked against the SHA-1 from the list before it is used.
public enum WindowsCatalogue {
    /// Microsoft's permanent link to the current list (it redirects to download.microsoft.com).
    public static let address = URL(string: "https://go.microsoft.com/fwlink/?LinkId=2156292")!

    /// One install image: all the editions of one kind (consumer or business) in one language.
    public struct Image: Equatable, Sendable {
        public var fileName: String
        /// As Microsoft writes it: `en-us`, `sr-latn-rs`.
        public var languageCode: String
        /// As Microsoft writes it: `English (United States)`.
        public var language: String
        public var bytes: Int64
        public var sha1: String
        public var url: URL
        /// Edition identifiers the image holds, as listed: `Professional`, `Core`, …
        public var editions: [String]

        /// `26100.4349` from `26100.4349.250607-1500.ge_release…`.
        public var build: String {
            let parts = fileName.split(separator: ".")
            return parts.count >= 2 && parts[0].allSatisfy(\.isNumber) && parts[1].allSatisfy(\.isNumber) ? "\(parts[0]).\(parts[1])" : ""
        }

        /// The language tag in the form Windows Setup takes: `en-US`, `sr-Latn-RS`.
        public var locale: String { WindowsCatalogue.locale(fromCode: languageCode) }
    }

    /// `en-us` → `en-US`, `sr-latn-rs` → `sr-Latn-RS`, `es-419` stays numeric.
    public static func locale(fromCode code: String) -> String {
        code.split(separator: "-").enumerated().map { index, part -> String in
            if index == 0 { return part.lowercased() }
            if part.count == 4 { return part.prefix(1).uppercased() + part.dropFirst().lowercased() }
            return part.uppercased()
        }.joined(separator: "-")
    }

    /// The ARM64 consumer images (Home and Pro) in the list, one per language, in the list's order.
    public static func consumerImages(inProductsXML data: Data) throws -> [Image] {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else {
            throw VMError("Microsoft's list of Windows images could not be read.", detail: parser.parserError?.localizedDescription ?? "It is not valid XML.")
        }
        var byFile: [String: Image] = [:]
        var order: [String] = []
        for file in reader.files {
            guard file["Architecture"]?.uppercased() == "ARM64",
                  let name = file["FileName"], name.uppercased().contains("CLIENTCONSUMER"), name.lowercased().hasSuffix(".esd"),
                  let code = file["LanguageCode"], let sha1 = file["Sha1"]?.lowercased(), sha1.count == 40, sha1.allSatisfy(\.isHexDigit),
                  let bytes = file["Size"].flatMap(Int64.init), bytes > 0,
                  let path = file["FilePath"], let url = URL(string: path), let host = url.host,
                  // Only Microsoft's own download servers are ever fetched from.
                  host.hasSuffix(".microsoft.com") || host.hasSuffix(".windowsupdate.com") else { continue }
            let edition = file["Edition"] ?? ""
            if var known = byFile[name] {
                if !edition.isEmpty, !known.editions.contains(edition) { known.editions.append(edition); byFile[name] = known }
            } else {
                byFile[name] = Image(fileName: name, languageCode: code.lowercased(), language: file["Language"] ?? code, bytes: bytes,
                                     sha1: sha1, url: url, editions: edition.isEmpty ? [] : [edition])
                order.append(name)
            }
        }
        return order.compactMap { byFile[$0] }
    }

    /// Pulls `products.xml` out of the cabinet file with the system's own archive tool.
    public static func productsXML(fromCabinet cab: URL) throws -> Data {
        let result = try ToolRun.run(URL(fileURLWithPath: "/usr/bin/bsdtar"), ["-xOf", cab.path, "products.xml"],
                                     timeout: ToolRun.Limit.quick, errors: .discard)
        let data = result.output
        guard result.succeeded, !data.isEmpty else {
            throw VMError("Microsoft's list of Windows images could not be unpacked.", detail: "\(cab.lastPathComponent) is not a cabinet file holding products.xml.")
        }
        return data
    }

    /// Fetches today's list. The file is kept for the day, so listing and then creating asks Microsoft once.
    public static func load(using downloads: Downloader) async throws -> [Image] {
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let request = DownloadRequest(url: address, fileName: "windows11-products-\(day).cab")
        // Lists of earlier days are no longer needed.
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: downloads.cache.path)) ?? []
        where name.hasPrefix("windows11-products-") && !name.hasPrefix(request.fileName) {
            try? fm.removeItem(at: downloads.cache.appendingPathComponent(name))
        }
        let cab: URL
        do { cab = try await downloads.fetch(request) }
        catch is CancellationError { throw CancellationError() }
        catch {
            throw VMError("Microsoft's list of Windows images could not be loaded.",
                          detail: "\(error.localizedDescription) Check the Internet connection and try again.")
        }
        do {
            let images = try consumerImages(inProductsXML: try productsXML(fromCabinet: cab))
            guard !images.isEmpty else { throw VMError("Microsoft's list has no Windows 11 image for ARM64.") }
            return images
        } catch {
            // A damaged list must not be reused for the rest of the day.
            downloads.remove(request)
            throw error
        }
    }

    /// Collects the child elements of every `<File>` as text.
    private final class Reader: NSObject, XMLParserDelegate {
        var files: [[String: String]] = []
        private var current: [String: String]?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "File" { current = [:] }
            text = ""
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "File" {
                if let current { files.append(current) }
                current = nil
            } else if current != nil {
                current?[name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            text = ""
        }
    }
}
