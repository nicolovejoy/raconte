import Foundation

/// Full reducer state (design §2/§6). Richer than the bare `CaptureState` enum
/// because the reducer must track the monotonic sequence number, the current
/// live-segment index, and the resume/finalize retry counters that decide rows
/// 10/11 and 17/18. `CaptureState` remains the persisted `phase`.
struct MachineState: Sendable, Equatable {
    var phase: CaptureState
    /// Monotonic; strictly increases on every accepted transition, never resets.
    var stateSeq: Int
    /// ULID of the active capture, `nil` while idle.
    var captureID: String?
    /// Index of the current live segment (the one open for writing).
    var segmentIndex: Int
    /// Resume attempts already spent (rows 10/11).
    var retryCount: Int
    /// Finalize attempts already spent (rows 17/18).
    var finalizeAttempts: Int

    static let idle = MachineState(
        phase: .idle, stateSeq: 0, captureID: nil,
        segmentIndex: 0, retryCount: 0, finalizeAttempts: 0)
}

/// Pure capture state machine (design §2/§6): `(MachineState, Event) -> (MachineState, [Effect])`.
/// No I/O, no time, no hardware, no AVFoundation — trivially `Sendable`.
struct CaptureMachine: Sendable {
    /// Resume retries allowed before giving up live (row 10 count < budget, else row 11).
    var resumeRetryBudget: Int = 3
    /// Finalize retries allowed before flagging needsAttention (row 17 count < budget, else row 18).
    var finalizeBudget: Int = 3

    init(resumeRetryBudget: Int = 3, finalizeBudget: Int = 3) {
        self.resumeRetryBudget = resumeRetryBudget
        self.finalizeBudget = finalizeBudget
    }

    /// Reduce an event against the current state. Illegal (state, event) pairs are
    /// no-ops: the state is returned unchanged and `[]` is emitted (stateSeq unmoved).
    func reduce(_ state: MachineState, _ event: Event) -> (MachineState, [Effect]) {
        switch (state.phase, event) {

        // Row 1 — idle -> preparing.
        case (.idle, .record(let captureID)):
            var next = state
            next.phase = .preparing
            next.stateSeq += 1
            next.captureID = captureID
            next.segmentIndex = 0
            next.retryCount = 0
            next.finalizeAttempts = 0
            return (next, [
                .createCaptureDirectory(captureID: captureID),
                .writeManifest(.init(state: .preparing, stateSeq: next.stateSeq)),
                .requestPermissionAndConfigure,
            ])

        // Row 2 — preparing -> recording.
        case (.preparing, .engineReady):
            var next = state
            next.phase = .recording
            next.stateSeq += 1
            next.segmentIndex = 0
            return (next, [
                .writeManifest(.init(state: .recording, stateSeq: next.stateSeq)),
                .installTapAndOpenSegment(index: 0),
            ])

        // Row 3 — preparing -> idle (permission denied / config fail).
        case (.preparing, .prepareFailed(let error)):
            var next = state
            next.phase = .idle
            next.stateSeq += 1
            next.captureID = nil
            next.segmentIndex = 0
            next.retryCount = 0
            next.finalizeAttempts = 0
            return (next, [
                .tearDownEngine,
                .surfaceError(error),
                .deleteCaptureDirectory,
            ])

        // Row 4 — recording -> recording (rotation).
        case (.recording, .rotationTick):
            let closedIndex = state.segmentIndex
            let segmentCount = closedIndex + 1
            var next = state
            next.stateSeq += 1
            next.segmentIndex = closedIndex + 1
            return (next, [
                .closeLiveSegment(reason: .rotation),
                .writeManifest(.init(state: .recording, stateSeq: next.stateSeq, segmentCount: segmentCount)),
                .openNextSegment(index: next.segmentIndex),
            ])

        // Rows 5 & 6 — recording -> interrupted (interruption began / route lost).
        case (.recording, .interruptionBegan), (.recording, .routeLost):
            return interrupt(from: state, discardEngine: false)

        // Row 7 — recording -> interrupted (media services reset).
        case (.recording, .mediaServicesReset):
            return interrupt(from: state, discardEngine: true)

        // Row 8 — interrupted -> resuming.
        case (.interrupted, .resume):
            var next = state
            next.phase = .resuming
            next.stateSeq += 1
            return (next, [
                .writeManifest(.init(state: .resuming, stateSeq: next.stateSeq)),
                .rebuildSessionAndEngine,
            ])

        // Row 9 — resuming -> recording (engine restarted OK).
        case (.resuming, .engineReady):
            var next = state
            next.phase = .recording
            next.stateSeq += 1
            next.retryCount = 0
            return (next, [
                .writeManifest(.init(state: .recording, stateSeq: next.stateSeq)),
                .installTapAndOpenSegment(index: next.segmentIndex),
            ])

        // Rows 10 & 11 — resuming -> interrupted (budget left) / captured (exhausted).
        case (.resuming, .reacquireFailed):
            if state.retryCount < resumeRetryBudget {
                var next = state
                next.phase = .interrupted
                next.stateSeq += 1
                next.retryCount = state.retryCount + 1
                return (next, [
                    .writeManifest(.init(state: .interrupted, stateSeq: next.stateSeq, retryCount: next.retryCount)),
                    .scheduleResumeBackoff,
                ])
            } else {
                var next = state
                next.phase = .captured
                next.stateSeq += 1
                return (next, [
                    .writeManifest(.init(state: .captured, stateSeq: next.stateSeq)),
                ])
            }

        // Row 12 — recording -> stopping (user taps Done).
        case (.recording, .done):
            var next = state
            next.phase = .stopping
            next.stateSeq += 1
            return (next, [
                .writeManifest(.init(state: .stopping, stateSeq: next.stateSeq)),
                .beginFlushWindow,
            ])

        // Row 13 — stopping -> captured (tail drained).
        case (.stopping, .tailDrained):
            let segmentCount = state.segmentIndex + 1
            var next = state
            next.phase = .captured
            next.stateSeq += 1
            next.segmentIndex = state.segmentIndex + 1
            return (next, [
                .closeLiveSegment(reason: .stop),
                .stopEngine,
                .releaseSession,
                .writeManifest(.init(state: .captured, stateSeq: next.stateSeq, segmentCount: segmentCount)),
            ])

        // Row 14 — interrupted -> captured (user taps Done; nothing new to close).
        case (.interrupted, .done):
            var next = state
            next.phase = .captured
            next.stateSeq += 1
            return (next, [
                .writeManifest(.init(state: .captured, stateSeq: next.stateSeq)),
            ])

        // Row 15 — captured -> finalizing (worker picks up).
        case (.captured, .finalizerPickup):
            var next = state
            next.phase = .finalizing
            next.stateSeq += 1
            return (next, [
                .writeManifest(.init(state: .finalizing, stateSeq: next.stateSeq)),
                .beginFinalize,
            ])

        // Row 16 — finalizing -> complete (encode + verify OK).
        case (.finalizing, .finalizeSucceeded):
            var next = state
            next.phase = .complete
            next.stateSeq += 1
            return (next, [
                .promoteFinalRecording,
                .writeManifest(.init(state: .complete, stateSeq: next.stateSeq, markFinalVerified: true)),
                .deleteRawSegments,
            ])

        // Rows 17 & 18 — finalizing -> captured (requeue / needsAttention).
        case (.finalizing, .finalizeFailed):
            if state.finalizeAttempts < finalizeBudget {
                var next = state
                next.phase = .captured
                next.stateSeq += 1
                next.finalizeAttempts = state.finalizeAttempts + 1
                return (next, [
                    .discardFinalPart,
                    .writeManifest(.init(state: .captured, stateSeq: next.stateSeq, finalizeAttempts: next.finalizeAttempts)),
                ])
            } else {
                var next = state
                next.phase = .captured
                next.stateSeq += 1
                return (next, [
                    .discardFinalPart,
                    .writeManifest(.init(state: .captured, stateSeq: next.stateSeq, needsAttention: true)),
                ])
            }

        // Row 19 — recording/stopping -> interrupted (disk full; no data-claiming).
        case (.recording, .diskFull), (.stopping, .diskFull):
            var next = state
            next.phase = .interrupted
            next.stateSeq += 1
            return (next, [
                .stopEngine,
                .surfaceError(.diskFull),
                .writeManifest(.init(state: .interrupted, stateSeq: next.stateSeq, lastError: .diskFull)),
            ])

        // Row 20 — any non-idle -> unchanged phase (last-gasp on termination).
        case (_, .appTerminating) where state.phase != .idle:
            var next = state
            next.stateSeq += 1
            var effects: [Effect] = []
            if state.phase == .recording || state.phase == .stopping {
                effects.append(.fsyncLiveSegment)
            }
            effects.append(.writeManifest(.init(state: state.phase, stateSeq: next.stateSeq, touchOnly: true)))
            return (next, effects)

        // Illegal event for the current state: no-op (stateSeq unmoved).
        default:
            return (state, [])
        }
    }

    /// Shared body for rows 5/6/7: close the live segment before the manifest flips.
    private func interrupt(from state: MachineState, discardEngine: Bool) -> (MachineState, [Effect]) {
        let segmentCount = state.segmentIndex + 1
        var next = state
        next.phase = .interrupted
        next.stateSeq += 1
        next.segmentIndex = state.segmentIndex + 1
        return (next, [
            discardEngine ? .discardEngine : .stopEngine,
            .closeLiveSegment(reason: .interruption),
            .writeManifest(.init(state: .interrupted, stateSeq: next.stateSeq,
                                 segmentCount: segmentCount, appendInterruption: true)),
        ])
    }
}
