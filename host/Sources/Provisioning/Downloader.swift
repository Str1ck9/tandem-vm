import CryptoKit
import Foundation
import VMCore

/// What a vendor publishes next to a file so a download can be checked.
public enum Checksum: Equatable, Sendable {
    case sha256(String), sha512(String), sha1(String)

    public var hex: String {
        switch self { case .sha256(let h), .sha512(let h), .sha1(let h): return h.lowercased() }
    }
    public var algorithm: String {
        switch self { case .sha256: return "sha256"; case .sha512: return "sha512"; case .sha1: return "sha1" }
    }
    /// The form kept beside a verified file, so it is not hashed again next time.
    var record: String { "\(algorithm):\(hex)" }

    /// The checksum of a file on disk, read in pieces (the files are gigabytes).
    public func matches(fileAt url: URL) throws -> Bool { try Self.digest(of: url, algorithm: algorithm) == hex }

    public static func digest(of url: URL, algorithm: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha256 = SHA256(), sha512 = SHA512(), sha1 = Insecure.SHA1()
        while true {
            let piece = try handle.read(upToCount: 4 << 20) ?? Data()
            if piece.isEmpty { break }
            switch algorithm {
            case "sha512": sha512.update(data: piece)
            case "sha1": sha1.update(data: piece)
            default: sha256.update(data: piece)
            }
        }
        func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
        switch algorithm {
        case "sha512": return hex(sha512.finalize())
        case "sha1": return hex(sha1.finalize())
        default: return hex(sha256.finalize())
        }
    }
}

public struct DownloadProgress: Equatable, Sendable {
    public var received: Int64
    /// Nil when the server does not say how large the file is.
    public var total: Int64?
    public var bytesPerSecond: Double
    public var fraction: Double? { total.flatMap { $0 > 0 ? min(1, Double(received) / Double($0)) : nil } }

    /// "412 MB of 1.2 GB, 18 MB/s"
    public var summary: String {
        let f = ByteCountFormatter(); f.countStyle = .file
        var text = f.string(fromByteCount: received)
        if let total { text += " of " + f.string(fromByteCount: total) }
        if bytesPerSecond > 0 { text += ", " + f.string(fromByteCount: Int64(bytesPerSecond)) + "/s" }
        return text
    }
}

public struct DownloadRequest: Sendable {
    public var url: URL
    /// Name in the cache folder. Defaults to the last part of the address.
    public var fileName: String
    public var checksum: Checksum?
    /// The size the vendor states, when known before the server is asked.
    public var expectedBytes: Int64?

    public init(url: URL, fileName: String? = nil, checksum: Checksum? = nil, expectedBytes: Int64? = nil) {
        self.url = url; self.fileName = fileName ?? url.lastPathComponent; self.checksum = checksum; self.expectedBytes = expectedBytes
    }
}

/// Downloads large files into a cache folder: an interrupted download carries on where it stopped,
/// a finished one is checked against the vendor's checksum, and a file already checked is used again.
///
/// In the cache: `<name>` is a complete, checked file; `<name>.partial` is one still arriving;
/// `<name>.sum` records which checksum the complete file passed.
public final class Downloader: @unchecked Sendable {
    public let cache: URL
    private let configuration: URLSessionConfiguration
    /// Sent with every request. Says nothing about the user or the Mac.
    public static let userAgent = "Tandem/1.0"

    /// The free space on the volume holding a folder (nil: unknown, which is not checked). Tests set it so
    /// that a tiny stubbed transfer does not depend on how full the test Mac's disk is.
    public var freeSpace: @Sendable (URL) -> Int64? = Downloader.volumeFreeSpace

    public static let volumeFreeSpace: @Sendable (URL) -> Int64? = { folder in
        (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    public init(cache: URL, configuration: URLSessionConfiguration = .ephemeral) {
        self.cache = cache
        let configuration = configuration
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        configuration.timeoutIntervalForRequest = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.configuration = configuration
    }

    public func finalURL(_ request: DownloadRequest) -> URL { cache.appendingPathComponent(request.fileName) }
    public func partialURL(_ request: DownloadRequest) -> URL { cache.appendingPathComponent(request.fileName + ".partial") }
    private func recordURL(_ request: DownloadRequest) -> URL { cache.appendingPathComponent(request.fileName + ".sum") }

    /// A small text file, such as a vendor's checksum list or release index.
    public func text(_ url: URL) async throws -> String {
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VMError("\(url.host ?? "The server") did not provide \(url.lastPathComponent).",
                          detail: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(url.absoluteString)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// How large the file at an address is, when the server says. Never throws: nil means unknown.
    public func size(of url: URL) async -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse,
              http.statusCode == 200, http.expectedContentLength > 0 else { return nil }
        return http.expectedContentLength
    }

    /// True when the complete file is in the cache and has passed this request's checksum.
    public func isCached(_ request: DownloadRequest) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: finalURL(request).path) else { return false }
        guard let checksum = request.checksum else { return true }
        return (try? String(contentsOf: recordURL(request), encoding: .utf8)) == checksum.record
    }

    /// Returns the complete, checked file, downloading whatever part of it is missing.
    /// Cancelling the task keeps the partial file, so the next call carries on from there.
    public func fetch(_ request: DownloadRequest, progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let final = finalURL(request), partial = partialURL(request), record = recordURL(request)

        if fm.fileExists(atPath: final.path) {
            if isCached(request) { return final }
            // Complete but never checked against this checksum (or checked against another): check it now.
            if let checksum = request.checksum, (try? checksum.matches(fileAt: final)) == true {
                try? Data(checksum.record.utf8).write(to: record)
                return final
            }
            try? fm.removeItem(at: final)
            try? fm.removeItem(at: record)
        }

        // A second attempt covers a partial file the server will not continue (it changed, or is already whole).
        for attempt in 0..<2 {
            let transfer = Transfer(request: request, partial: partial, freeSpace: freeSpace, progress: progress)
            let outcome = try await transfer.run(configuration: configuration)
            if outcome == .restart {
                try? fm.removeItem(at: partial)
                if attempt == 0 { continue }
                throw VMError("\(request.fileName) could not be downloaded.", detail: "The server refused to continue or restart the download.")
            }
            break
        }

        if let checksum = request.checksum {
            guard try checksum.matches(fileAt: partial) else {
                try? fm.removeItem(at: partial)
                throw VMError("The download of \(request.fileName) is damaged and was deleted.",
                              detail: "Its \(checksum.algorithm) checksum does not match the one published at \(request.url.host ?? "the source"). Try again.")
            }
        }
        try? fm.removeItem(at: final)
        try fm.moveItem(at: partial, to: final)
        if let checksum = request.checksum { try? Data(checksum.record.utf8).write(to: record) } else { try? fm.removeItem(at: record) }
        return final
    }

    /// Removes a file and everything kept beside it.
    public func remove(_ request: DownloadRequest) {
        for url in [finalURL(request), partialURL(request), recordURL(request)] { try? FileManager.default.removeItem(at: url) }
    }
}

/// One HTTP transfer into a partial file.
private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome { case done, restart }

    private let request: DownloadRequest
    private let partial: URL
    private let freeSpace: @Sendable (URL) -> Int64?
    private let progress: @Sendable (DownloadProgress) -> Void
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var total: Int64?
    private var continuation: CheckedContinuation<Outcome, Error>?
    private var failure: Error?
    private var restart = false
    // Speed over the last few seconds, and at most a few progress calls a second.
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    private var lastReport: TimeInterval = 0

    init(request: DownloadRequest, partial: URL, freeSpace: @escaping @Sendable (URL) -> Int64?,
         progress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.request = request; self.partial = partial; self.freeSpace = freeSpace; self.progress = progress
    }

    func run(configuration: URLSessionConfiguration) async throws -> Outcome {
        let fm = FileManager.default
        let existing = ((try? fm.attributesOfItem(atPath: partial.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if existing == 0 { fm.createFile(atPath: partial.path, contents: nil) }
        received = existing
        var urlRequest = URLRequest(url: request.url)
        if existing > 0 { urlRequest.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: urlRequest)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    self.continuation = continuation
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func fail(_ error: Error, _ task: URLSessionTask) {
        if failure == nil { failure = error }
        task.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        do {
            switch http.statusCode {
            case 206:
                // The server continues from where the partial file ends.
                total = received + max(http.expectedContentLength, 0)
                handle = try FileHandle(forWritingTo: partial)
                try handle?.seekToEnd()
            case 200:
                // The whole file from the start (a new download, or a server that ignores ranges).
                received = 0
                total = http.expectedContentLength > 0 ? http.expectedContentLength : request.expectedBytes
                handle = try FileHandle(forWritingTo: partial)
                try handle?.truncate(atOffset: 0)
            case 416:
                // Nothing beyond the partial file: it is whole if it has the stated size, stale otherwise.
                if let expected = request.expectedBytes, expected == received {
                    total = expected
                    completionHandler(.cancel)
                    return
                }
                restart = true
                completionHandler(.cancel)
                return
            default:
                throw VMError("\(request.url.host ?? "The server") refused the download of \(request.fileName).",
                              detail: "HTTP \(http.statusCode) for \(request.url.absoluteString)")
            }
            if let total {
                let needed = total - received
                // Room for the file, and 2 GB to spare.
                if let free = freeSpace(partial.deletingLastPathComponent()), free < needed + (2 << 30) {
                    let f = ByteCountFormatter(); f.countStyle = .file
                    throw VMError("There is not enough free disk space to download \(request.fileName).",
                                  detail: "It needs \(f.string(fromByteCount: needed)) and 2 GB to spare; \(f.string(fromByteCount: free)) is free.")
                }
            }
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try handle?.write(contentsOf: data) } catch { fail(error, dataTask); return }
        received += Int64(data.count)
        let now = Date().timeIntervalSinceReferenceDate
        samples.append((now, received))
        samples.removeAll { now - $0.time > 5 }
        guard now - lastReport >= 0.25 else { return }
        lastReport = now
        report(now: now)
    }

    private func report(now: TimeInterval) {
        var speed = 0.0
        if let first = samples.first, now - first.time > 0.5 { speed = Double(received - first.bytes) / (now - first.time) }
        progress(DownloadProgress(received: received, total: total, bytesPerSecond: speed))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        let continuation = self.continuation
        self.continuation = nil
        if let failure { continuation?.resume(throwing: failure); return }
        if restart { continuation?.resume(returning: .restart); return }
        if let error {
            let ns = error as NSError
            // A 416 answered with "cancel" also arrives here as a cancellation; that one is a success.
            if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled {
                if let total, total == received, request.expectedBytes == received { continuation?.resume(returning: .done) }
                else { continuation?.resume(throwing: CancellationError()) }
                return
            }
            continuation?.resume(throwing: VMError("The download of \(request.fileName) stopped.",
                                                   detail: "\(ns.localizedDescription) It carries on from where it stopped when you try again."))
            return
        }
        if let total, total != received {
            continuation?.resume(throwing: VMError("The download of \(request.fileName) ended early.",
                                                   detail: "Received \(received) of \(total) bytes. It carries on from where it stopped when you try again."))
            return
        }
        report(now: Date().timeIntervalSinceReferenceDate)
        continuation?.resume(returning: .done)
    }
}
