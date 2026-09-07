import Foundation
import CryptoKit

/// The one sha256-hex formula in the app. Hoisted out of `SyncTreeScanner` (T3) once
/// `ArchiveExporter`/`ArchiveVerifier` (T11/T12) needed the identical computation —
/// `SyncTreeScanner.sha256Hex`/`ImageStore.sha256Hex` now both delegate here rather than
/// carrying their own copies of `SHA256.hash(data:).map { String(format: "%02x", $0) }`.
enum SHA256Hex {
    /// Full lowercase-hex sha256 of `data`, verbatim.
    static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Same digest, read from disk. `.mappedIfSafe` avoids fully residentizing a large
    /// file (the final m4a can be tens of MB) just to hash it.
    static func ofFile(at url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return of(data)
    }
}
