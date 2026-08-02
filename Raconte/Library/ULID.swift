import Foundation

/// Lexicographically-sortable, time-prefixed ID (M1 design §1 `captureID`): a 48-bit
/// millisecond timestamp plus 80 bits of randomness, Crockford base32, 26 chars.
///
/// Extracted from `CaptureCoordinator.makeULID` (which now calls this) because M3 mints
/// IDs for journals too, and "the capture coordinator" is the wrong owner of an ID scheme
/// that is about to key three different kinds of thing. Byte-for-byte the same algorithm;
/// `CaptureViewModelTests`' round-trip against `FinishedRecording.timestamp(fromULID:)`
/// still covers it.
enum ULID {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let length = 26

    static func make(now: Date = Date()) -> String {
        var value = UInt64(max(0, now.timeIntervalSince1970) * 1000)
        var time = [Character](repeating: "0", count: 10)
        for i in (0..<10).reversed() { time[i] = alphabet[Int(value & 0x1F)]; value >>= 5 }
        var random = [Character](repeating: "0", count: 16)
        for i in 0..<16 { random[i] = alphabet[Int.random(in: 0..<32)] }
        return String(time) + String(random)
    }

    /// The instant encoded in the first 10 Crockford-base32 characters (a 48-bit
    /// millisecond timestamp), or nil if they aren't. Lets a capture whose manifest is
    /// missing or corrupt still carry its own date — the library sorts by it.
    ///
    /// Only the prefix is examined, so a truncated-but-well-formed head still decodes;
    /// use `isWellFormed` when the whole id matters.
    static func timestamp(from id: String) -> Date? {
        let head = id.uppercased().prefix(10)
        guard head.count == 10 else { return nil }
        var ms: UInt64 = 0
        for character in head {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            ms = (ms << 5) | UInt64(value)
        }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    /// Shape check only — 26 Crockford-base32 characters. Used to reject obvious
    /// garbage in a decoded identity field, not to prove an ID was ever minted here.
    static func isWellFormed(_ id: String) -> Bool {
        let upper = id.uppercased()
        return upper.count == length && upper.allSatisfy { alphabet.contains($0) }
    }
}
