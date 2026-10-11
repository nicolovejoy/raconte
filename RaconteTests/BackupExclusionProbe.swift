import XCTest

/// Whether this environment can set the backup-exclusion flag and read it back.
///
/// On GitHub Actions macOS runners, backupd is unreachable over XPC —
/// "_CSBackupIsItemExcluded_Remote(): XPC error for connection
/// com.apple.backupd.sandbox.xpc: Connection invalid" (observed 2026-08-07) — so
/// `isExcludedFromBackup` can neither be set nor read back there, independent of what the
/// code under test does. Measure the environment rather than assume it, so any future
/// sandbox with the same limitation is covered too.
///
/// Only a test that asserts a directory IS excluded needs this. "Is not excluded" holds
/// everywhere.
enum BackupExclusionProbe {
    /// Sets the flag on a scratch directory under `parent`, reads it back, and removes the
    /// directory again.
    static func flagCanBeSetAndReadBack(under parent: URL) throws -> Bool {
        var probe = parent.appendingPathComponent("backup-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probe) }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try probe.setResourceValues(values)
        } catch {
            return false
        }
        let readBack = try? probe.resourceValues(forKeys: [.isExcludedFromBackupKey])
        return readBack?.isExcludedFromBackup == true
    }

    /// Skips the calling test where the flag cannot be measured.
    static func skipUnlessTheFlagCanBeMeasured(under parent: URL,
                                               file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTSkipIf(!flagCanBeSetAndReadBack(under: parent),
                      "backupd unreachable in this environment — the backup-exclusion flag "
                      + "cannot be measured (seen on GitHub Actions runners)",
                      file: file, line: line)
    }
}
