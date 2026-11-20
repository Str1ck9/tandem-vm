import Foundation

extension Error {
    /// What the user reads: the message, then its detail, and for plain system errors a sentence that
    /// says what happened instead of "The operation couldn't be completed (… error N)".
    public var userFacingText: String {
        if let vm = self as? VMError {
            return [vm.message, vm.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        let ns = self as NSError
        if let plain = Self.plainPOSIX(ns) { return plain }
        var lines = [ns.localizedDescription]
        if let reason = ns.localizedFailureReason, !ns.localizedDescription.contains(reason) { lines.append(reason) }
        if let suggestion = ns.localizedRecoverySuggestion { lines.append(suggestion) }
        return lines.joined(separator: "\n")
    }

    private static func plainPOSIX(_ error: NSError) -> String? {
        let code: Int32?
        if error.domain == NSPOSIXErrorDomain { code = Int32(error.code) }
        else if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain { code = Int32(underlying.code) }
        else { code = nil }
        let path = (error.userInfo[NSFilePathErrorKey] as? String).map { " (\($0))" } ?? ""
        switch code {
        case ENOSPC?: return "The Mac's disk is full\(path). Free up space and try again."
        case EACCES?, EPERM?: return "macOS did not allow access\(path). Check the file's permissions, or Privacy & Security in System Settings."
        case ENOENT?: return "A file Tandem needs is missing\(path)."
        case EROFS?: return "The disk is read-only\(path)."
        default: return nil
        }
    }
}
