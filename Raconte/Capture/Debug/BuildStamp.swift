#if DEBUG
import Foundation
import MachO

/// A single on-disk file's modification time, considered as evidence of when
/// this bundle's contents were last written to disk.
struct BuildFileStamp: Equatable {
    let url: URL
    let modificationDate: Date
}

/// Runtime evidence of this build, read from the app bundle rather than
/// stamped by the build system.
///
/// Two constraints, both real and both probe-confirmed:
///
/// 1. Debug builds put nearly all app code into a `*.debug.dylib` inside the
///    bundle; the main executable is a thin stub. `representativeFile` picks
///    the newest mtime among the executable and any `*.debug.dylib` so the
///    displayed evidence reflects the real build artifact, not the stub.
/// 2. mtime is copy time, not link time. The owner receives builds by
///    copying the .app to `~/Desktop`, and a plain `cp -R` resets every
///    file's mtime to the copy moment (only `ditto`/`cp -Rp` preserve it) —
///    so the date alone can silently vouch for a stale build. The display
///    is worded "Binary file date", never "Built", and is paired with the
///    Mach-O LC_UUID identity (content-derived, survives any copy),
///    comparable against `dwarfdump --uuid` on the build products.
enum BuildStamp {
    // MARK: representativeFile

    static func representativeFile(among candidates: [BuildFileStamp]) -> BuildFileStamp? {
        candidates.max(by: { $0.modificationDate < $1.modificationDate })
    }

    // MARK: candidate selection

    /// Which bundle files count as build evidence for the mtime comparison.
    /// Deliberately excludes `__preview.dylib` (an Xcode Previews artifact
    /// that can be newer than the real build and would poison the max).
    static func isBuildEvidence(fileName: String) -> Bool {
        fileName.hasSuffix(".debug.dylib")
    }

    /// Testable core: walks `directory` for build-evidence files, plus the
    /// given executable if present, each paired with its filesystem
    /// modification date.
    static func candidates(
        inDirectory directory: URL,
        executableURL: URL?,
        fileManager: FileManager = .default
    ) -> [BuildFileStamp] {
        var urls: [URL] = []
        if let executableURL {
            urls.append(executableURL)
        }
        if let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where isBuildEvidence(fileName: url.lastPathComponent) {
                urls.append(url)
            }
        }
        return urls.compactMap { url in
            guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                  let date = attrs[.modificationDate] as? Date
            else { return nil }
            return BuildFileStamp(url: url, modificationDate: date)
        }
    }

    /// I/O entry point: candidates within the running app's own bundle.
    static func currentBuildCandidates(bundle: Bundle = .main, fileManager: FileManager = .default) -> [BuildFileStamp] {
        candidates(inDirectory: bundle.bundleURL, executableURL: bundle.executableURL, fileManager: fileManager)
    }

    // MARK: date display

    /// Displays a file's on-disk date per the UTC-at-rest/Pacific-on-display
    /// convention: always rendered in America/Los_Angeles regardless of the
    /// device's own timezone. Labelled "Binary file date", not "Built" —
    /// mtime is copy time on a `cp`-distributed build, not link time.
    static func displayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        // "America/Los_Angeles" is a fixed IANA identifier that is always
        // valid; force-unwrapping makes a lookup failure crash loudly in
        // DEBUG rather than silently falling back to the device's timezone.
        formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return "Binary file date \(formatter.string(from: date)) PT"
    }

    // MARK: build identity (Mach-O LC_UUID)

    /// First 8 hex characters of a Mach-O image UUID — a short, stable
    /// identity string. `UUID.uuidString` is `8-4-4-4-12` with hyphens
    /// starting at index 8, so this prefix is always pure hex.
    static func shortIdentity(from uuid: UUID) -> String {
        String(uuid.uuidString.prefix(8))
    }

    /// The LC_UUID of a loaded dyld image at the given file path, by walking
    /// that image's Mach-O load commands. Content-derived, so unlike mtime
    /// it cannot be reset by copying the file — the same build always
    /// carries the same UUID, comparable against `dwarfdump --uuid`.
    static func loadedImageUUID(forExecutablePath path: String) -> UUID? {
        let count = _dyld_image_count()
        for index in 0..<count {
            guard let namePtr = _dyld_get_image_name(index), String(cString: namePtr) == path else { continue }
            return machOUUID(atImageIndex: index)
        }
        return nil
    }

    private static func machOUUID(atImageIndex index: UInt32) -> UUID? {
        guard let header = _dyld_get_image_header(index) else { return nil }
        return header.withMemoryRebound(to: mach_header_64.self, capacity: 1) { header64 -> UUID? in
            guard header64.pointee.magic == MH_MAGIC_64 else { return nil }
            var cursor = UnsafeRawPointer(header64).advanced(by: MemoryLayout<mach_header_64>.size)
            for _ in 0..<header64.pointee.ncmds {
                let command = cursor.load(as: load_command.self)
                if command.cmd == LC_UUID {
                    let uuidCommand = cursor.load(as: uuid_command.self)
                    return UUID(uuid: uuidCommand.uuid)
                }
                cursor = cursor.advanced(by: Int(command.cmdsize))
            }
            return nil
        }
    }

    // MARK: full pipeline

    /// Full pipeline for the Debug screen row: date + identity, computed
    /// once by the caller (this does bundle I/O and a dyld image walk) and
    /// nil only if no candidate file could be found or stat'd, which should
    /// not happen in a real bundle.
    static func currentBuildDisplayString(bundle: Bundle = .main, fileManager: FileManager = .default) -> String? {
        guard let representative = representativeFile(
            among: currentBuildCandidates(bundle: bundle, fileManager: fileManager)
        ) else {
            return nil
        }
        let dateString = displayString(for: representative.modificationDate)
        guard let uuid = loadedImageUUID(forExecutablePath: representative.url.path) else {
            return dateString
        }
        return "\(dateString) · \(shortIdentity(from: uuid))"
    }
}
#endif
