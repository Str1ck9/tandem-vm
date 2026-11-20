import CryptoKit
import Foundation
import VMCore

/// Ed25519 signatures over a release. What is signed is a short text naming the version, the build, the
/// archive's length and SHA-256 and the release notes' SHA-256, so a valid signature cannot be moved to
/// another archive, another version (an old, signed release offered as new) or other notes.
///
/// Keys are the raw 32-byte Curve25519 keys, written as base64. The public key is in Tandem's Info.plist
/// (`TandemUpdatePublicKey`); the private key stays with the developer (`tandem-release keygen`), outside
/// the repository.
public enum UpdateSignature {
    public static let infoPlistKey = "TandemUpdatePublicKey"

    public static func message(for release: UpdateRelease) -> Data {
        let notes = SHA256.hash(data: Data((release.notes ?? "").utf8)).hex
        let text = """
        tandem-update-v1
        version=\(release.version)
        build=\(release.build)
        minimumSystemVersion=\(release.minimumSystemVersion ?? "")
        length=\(release.length)
        sha256=\(release.sha256.lowercased())
        notes-sha256=\(notes)

        """
        return Data(text.utf8)
    }

    public static func sign(_ release: UpdateRelease, with key: Curve25519.Signing.PrivateKey) throws -> String {
        try key.signature(for: message(for: release)).base64EncodedString()
    }

    /// Throws unless `release.signature` was made with the private half of `publicKey`.
    public static func verify(_ release: UpdateRelease, publicKey: Curve25519.Signing.PublicKey) throws {
        guard let signature = Data(base64Encoded: release.signature), signature.count == 64,
              publicKey.isValidSignature(signature, for: message(for: release)) else {
            throw VMError("The update’s signature is not valid.",
                          detail: "Tandem \(release.version) was not signed with Tandem’s release key, so it is not installed.")
        }
    }

    public static func publicKey(base64: String) throws -> Curve25519.Signing.PublicKey {
        guard let raw = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            throw VMError("The update key in this copy of Tandem is not valid.")
        }
        return key
    }

    /// The key this app trusts, from its Info.plist; nil for builds made without one.
    public static func publicKey(of bundle: Bundle) -> Curve25519.Signing.PublicKey? {
        guard let text = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String, !text.isEmpty else { return nil }
        return try? publicKey(base64: text)
    }

    // MARK: Private key files

    /// Reads a private key file (base64 of the raw 32 bytes, as `tandem-release keygen` writes it).
    public static func privateKey(at url: URL) throws -> Curve25519.Signing.PrivateKey {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 32,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
            throw VMError("\(url.path) is not a Tandem release key.")
        }
        return key
    }

    /// Writes a new private key, readable only by its owner, and returns it. Refuses to replace a key:
    /// a lost or replaced key means every installed copy of Tandem stops accepting updates.
    @discardableResult
    public static func generateKey(at url: URL) throws -> Curve25519.Signing.PrivateKey {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else {
            throw VMError("A release key already exists at \(url.path).", detail: "It is kept: copies of Tandem already trust it. Move it away yourself if you really mean to replace it.")
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = Curve25519.Signing.PrivateKey()
        let text = key.rawRepresentation.base64EncodedString() + "\n"
        guard fm.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw VMError("The release key could not be written to \(url.path).")
        }
        return key
    }

    /// `~/.config/tandem/update-signing.key`
    public static var defaultPrivateKeyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/tandem/update-signing.key")
    }

    // MARK: Archive digests

    /// SHA-256 and length of a file, read in pieces (an archive is hundreds of MB).
    public static func digest(of url: URL) throws -> (sha256: String, length: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var length: Int64 = 0
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            length += Int64(chunk.count)
        }
        return (hasher.finalize().hex, length)
    }

    /// Throws unless the downloaded archive is exactly the one the (already verified) release names.
    public static func check(archive url: URL, against release: UpdateRelease) throws {
        let actual = try digest(of: url)
        guard actual.length == release.length, actual.sha256 == release.sha256.lowercased() else {
            throw VMError("The downloaded update is damaged or not the one that was signed.",
                          detail: "Expected \(release.length) bytes with SHA-256 \(release.sha256.lowercased()); got \(actual.length) bytes with \(actual.sha256). Try again later.")
        }
    }
}

extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
