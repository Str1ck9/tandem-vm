import CryptoKit
import Foundation
import VMCore

/// Finds and downloads updates. No AppKit: the app, the release tool and the tests share it.
public struct UpdateClient: Sendable {
    public var feedURL: URL
    public var publicKey: Curve25519.Signing.PublicKey
    public var current: AppVersion

    public init(feedURL: URL, publicKey: Curve25519.Signing.PublicKey, current: AppVersion) {
        self.feedURL = feedURL; self.publicKey = publicKey; self.current = current
    }

    /// The default feed: the latest GitHub release of the project. While the repository is private GitHub
    /// answers 404 to anyone not signed in, which `fetchFeed` turns into a plain message.
    public static let defaultFeedURL = URL(string: TandemIdentity.projectURL + "/releases/latest/download/tandem-update.json")!
    public static let infoPlistFeedKey = "TandemUpdateFeedURL"

    /// Reads the feed (https or file).
    public func fetchFeed() async throws -> UpdateFeed {
        let data: Data
        if feedURL.isFileURL {
            do { data = try Data(contentsOf: feedURL) }
            catch { throw VMError("The update feed could not be read.", detail: "\(feedURL.path): \(error.localizedDescription)") }
        } else {
            var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Tandem/\(current.short)", forHTTPHeaderField: "User-Agent")
            let response: URLResponse
            do { (data, response) = try await URLSession.shared.data(for: request) }
            catch { throw VMError("Tandem could not reach its update feed.", detail: "\(feedURL.absoluteString)\n\(error.localizedDescription)") }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw Self.httpError(http.statusCode, feedURL)
            }
        }
        return try UpdateFeed.parse(data)
    }

    static func httpError(_ status: Int, _ url: URL) -> VMError {
        switch status {
        case 404:
            return VMError("No update feed was found.",
                           detail: "\(url.absoluteString) answered “not found”. While Tandem’s repository is private, GitHub shows its releases only to people signed in; set another feed under Settings > General, or install new versions by hand.")
        case 401, 403:
            return VMError("The update feed refused access (HTTP \(status)).", detail: url.absoluteString)
        default:
            return VMError("The update feed answered with an error (HTTP \(status)).", detail: url.absoluteString)
        }
    }

    /// The newest release newer than this copy, its signature checked. nil: up to date.
    public func check(skipping skipped: Set<String> = []) async throws -> UpdateRelease? {
        let feed = try await fetchFeed()
        // The signature is checked before anything of the release is shown.
        var candidates = feed
        while let release = candidates.newest(after: current, skipping: skipped) {
            do { try UpdateSignature.verify(release, publicKey: publicKey); return release }
            catch {
                // A bad entry must not hide an older good one, but an unsigned newest release is worth saying.
                candidates.releases.removeAll { $0 == release }
                if candidates.newest(after: current, skipping: skipped) == nil { throw error }
            }
        }
        return nil
    }

    /// Downloads the release's archive into `folder`, checks it is the signed one, and returns its path.
    /// A complete earlier download of the same archive is used again.
    public func download(_ release: UpdateRelease, into folder: URL,
                         progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        try UpdateSignature.verify(release, publicKey: publicKey)
        guard release.appVersion > current else { throw Self.notNewer(release, current) }
        guard let source = release.archiveURL(relativeTo: feedURL) else {
            throw VMError("The update’s address is not valid.", detail: release.url)
        }
        guard source.isFileURL || source.scheme == "https" else {
            throw VMError("The update is not offered over a secure connection.", detail: source.absoluteString)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(release.archiveFileName)
        if fm.fileExists(atPath: target.path), (try? UpdateSignature.check(archive: target, against: release)) != nil {
            progress(1); return target
        }
        try? fm.removeItem(at: target)
        let partial = folder.appendingPathComponent(release.archiveFileName + ".partial")
        try? fm.removeItem(at: partial)

        if source.isFileURL {
            do { try fm.copyItem(at: source, to: partial) }
            catch { throw VMError("The update could not be copied.", detail: "\(source.path): \(error.localizedDescription)") }
        } else {
            let delegate = DownloadProgress(expected: release.length, report: progress)
            var request = URLRequest(url: source, timeoutInterval: 60)
            request.setValue("Tandem/\(current.short)", forHTTPHeaderField: "User-Agent")
            let (temporary, response): (URL, URLResponse)
            do { (temporary, response) = try await URLSession.shared.download(for: request, delegate: delegate) }
            catch { throw VMError("The update could not be downloaded.", detail: "\(source.absoluteString)\n\(error.localizedDescription)") }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try? fm.removeItem(at: temporary)
                throw VMError("The update could not be downloaded (HTTP \(http.statusCode)).", detail: source.absoluteString)
            }
            try fm.moveItem(at: temporary, to: partial)
        }
        do { try UpdateSignature.check(archive: partial, against: release) }
        catch { try? fm.removeItem(at: partial); throw error }
        try fm.moveItem(at: partial, to: target)
        progress(1)
        return target
    }

    static func notNewer(_ release: UpdateRelease, _ current: AppVersion) -> VMError {
        VMError("Tandem \(release.appVersion) is not newer than this copy (\(current)).", detail: "Older versions are never installed over newer ones.")
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let expected: Int64
    let report: @Sendable (Double) -> Void
    init(expected: Int64, report: @escaping @Sendable (Double) -> Void) { self.expected = expected; self.report = report }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        if total > 0 { report(min(Double(totalBytesWritten) / Double(total), 1)) }
        // A server sending far more than the signed length is not sending the update.
        if totalBytesWritten > expected + (1 << 20) { downloadTask.cancel() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
