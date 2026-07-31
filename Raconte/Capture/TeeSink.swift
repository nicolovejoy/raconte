import Foundation

/// Fans one tap's PCM out to several sinks (M2 design §2: transcription is a
/// second consumer of the same chunks, never a rewiring of the disk path).
///
/// Checked `Sendable`, not `@unchecked`: the only stored property is an immutable
/// array of `Sendable` branches. **Never add mutable state here.** A counter or a
/// drop ledger would force `@unchecked` plus a lock taken on the real-time tap
/// thread for every chunk of every capture — that bookkeeping belongs in a branch
/// (`BoundedPCMSink`), which knows its own frame cursor.
///
/// Always constructed, even with a single branch: one tee identity means both
/// `recorder.start` sites (initial + resume) pass the same object, so a second
/// branch can't silently die at the first interruption.
final class TeeSink: PCMSink {
    let branches: [any PCMSink]

    init(branches: [any PCMSink]) {
        self.branches = branches
    }

    /// Called on the audio tap thread. No lock, no allocation, no `Task` — just
    /// the loop. `PCMChunk.data` is copy-on-write, so fanning to N branches costs
    /// N retains, not N copies.
    ///
    /// **Branch order is load-bearing, not cosmetic.** The tee runs on the
    /// caller's thread, so nothing preempts a slow branch; the disk branch is
    /// isolated purely by being entered first. Chunk N is on the pump's stream
    /// before any secondary branch is entered.
    nonisolated func receive(_ chunk: PCMChunk) {
        for branch in branches { branch.receive(chunk) }
    }
}
