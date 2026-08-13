#if DEBUG
import Foundation

/// A single on-disk file's modification time, considered as evidence of when
/// "the build" happened.
struct BuildFileStamp: Equatable {
    let url: URL
    let modificationDate: Date
}

/// Runtime evidence of when this build was produced, read from the app bundle
/// rather than stamped by the build system.
///
/// Debug builds put nearly all app code into a `*.debug.dylib` inside the
/// bundle; the main executable is a thin stub whose own link timestamp does
/// not track the last real rebuild. `representativeFile` picks the newest
/// mtime among the executable and any `*.debug.dylib` so the displayed date
/// reflects the actual last build under that constraint, not the stub.
enum BuildStamp {
    static func representativeFile(among candidates: [BuildFileStamp]) -> BuildFileStamp? {
        candidates.max(by: { $0.modificationDate < $1.modificationDate })
    }

    /// Displays a build timestamp per the UTC-at-rest/Pacific-on-display
    /// convention: the file's mtime is whatever the filesystem gives us, but
    /// it is always rendered in America/Los_Angeles regardless of the
    /// device's own timezone.
    static func displayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return "Built \(formatter.string(from: date)) PT"
    }

    /// Main executable plus any `*.debug.dylib` found in the bundle, each
    /// paired with its filesystem modification date. I/O only — not unit
    /// tested directly; `representativeFile` and `displayString` are the
    /// tested pure core.
    static func currentBuildCandidates(bundle: Bundle = .main) -> [BuildFileStamp] {
        let fm = FileManager.default
        var urls: [URL] = []
        if let exe = bundle.executableURL {
            urls.append(exe)
        }
        if let enumerator = fm.enumerator(
            at: bundle.bundleURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".debug.dylib") {
                urls.append(url)
            }
        }
        return urls.compactMap { url in
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let date = attrs[.modificationDate] as? Date
            else { return nil }
            return BuildFileStamp(url: url, modificationDate: date)
        }
    }

    /// Full pipeline for the Debug screen row: nil only if no candidate file
    /// could be found or stat'd, which should not happen in a real bundle.
    static func currentBuildDisplayString(bundle: Bundle = .main) -> String? {
        guard let representative = representativeFile(among: currentBuildCandidates(bundle: bundle)) else {
            return nil
        }
        return displayString(for: representative.modificationDate)
    }
}
#endif
