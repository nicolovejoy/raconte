import Foundation
import os

/// Keeps the index in step with the files after every library scan. Read-only against
/// `captures/` — never a write there, never a `noteLocalChange`.
actor SearchIndexer {
    struct Entry: Sendable, Equatable {
        var captureID: String
        var directory: URL
    }

    struct Report: Sendable, Equatable {
        var indexed = 0
        var removed = 0
        var unchanged = 0
        var failed = 0

        /// True when the pass wrote something a query could answer differently for.
        /// Failures and unchanged entries wrote nothing.
        var changedTheIndex: Bool { indexed + removed > 0 }
    }

    private let index: SearchIndex
    private static let log = Logger(subsystem: "org.pianohouseproject.raconte", category: "search")

    init(index: SearchIndex) { self.index = index }

    func reconcile(_ entries: [Entry]) async -> Report {
        let started = ContinuousClock.now
        var report = Report()
        var known: [String: String] = [:]
        do {
            known = try await index.fingerprints()
        } catch {
            Self.log.notice("search: fingerprints unreadable, the index will be rebuilt: \(error.localizedDescription, privacy: .public)")
        }
        let listed = Set(entries.map(\.captureID))
        let gone = known.keys.filter { !listed.contains($0) }
        if !gone.isEmpty {
            do {
                try await index.remove(captureIDs: Array(gone))
                report.removed = gone.count
            } catch {
                report.failed += gone.count
                Self.log.notice("search: removing \(gone.count) gone entries failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        for entry in entries {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                report.failed += 1
                Self.log.notice("search: capture directory missing for \(entry.captureID, privacy: .public)")
                continue
            }
            // Fingerprint first, body second. If a write lands between the two reads, this
            // order stores an old fingerprint with a new body and the next scan re-indexes;
            // the reverse would store a new fingerprint with an old body and miss it for good.
            guard let fingerprint = SearchFingerprint.compute(directory: entry.directory) else {
                // Nothing transcribed yet — not an error, nothing to find.
                await dropIfKnown(entry.captureID, known: known, report: &report)
                continue
            }
            if known[entry.captureID] == fingerprint {
                report.unchanged += 1
                continue
            }
            guard let body = EntryTranscriptLoader.fullText(captureDirectory: entry.directory) else {
                await dropIfKnown(entry.captureID, known: known, report: &report)
                continue
            }
            do {
                try await index.upsert(captureID: entry.captureID, fingerprint: fingerprint, body: body)
                report.indexed += 1
            } catch {
                report.failed += 1
                Self.log.notice("search: index write failed for \(entry.captureID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if report.indexed + report.removed + report.failed > 0 {
            let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
            Self.log.notice("search: reconcile indexed=\(report.indexed) removed=\(report.removed) unchanged=\(report.unchanged) failed=\(report.failed) in \(ms)ms")
        }
        return report
    }

    private func dropIfKnown(_ captureID: String, known: [String: String], report: inout Report) async {
        guard known[captureID] != nil else { return }
        do {
            try await index.remove(captureIDs: [captureID])
            report.removed += 1
        } catch {
            report.failed += 1
            Self.log.notice("search: removing \(captureID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
