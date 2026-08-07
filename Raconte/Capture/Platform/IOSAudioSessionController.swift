#if os(iOS)
import Foundation
import AVFAudio

final class IOSAudioSessionController: AudioSessionController, @unchecked Sendable {
    let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let center: NotificationCenter
    private let tokens: [NSObjectProtocol]
    private let session = AVAudioSession.sharedInstance()

    init(center: NotificationCenter = .default) {
        self.center = center
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
        self.tokens = Self.observe(center: center, continuation: continuation)
    }

    deinit {
        tokens.forEach { center.removeObserver($0) }
        continuation.finish()
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in cont.resume(returning: granted) }
        }
    }

    func activate() async throws {
        try session.setCategory(.playAndRecord,
                                mode: .spokenAudio,
                                options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker])
        try? session.setPreferredIOBufferDuration(0.02)
        // iOS suppresses haptics and system sounds while a recording session is active
        // unless the app opts in here. Without this, the capture screen's structure-marker
        // buttons (T6 §14 design §5) update on disk and in the UI but never buzz — the felt
        // confirmation is silently dropped. Accepted trade-off: the haptic motor's buzz can
        // faintly bleed into the mic. Non-critical: never block capture on this failing.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
    }

    func deactivate() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func observe(center: NotificationCenter,
                                continuation: AsyncStream<SessionEvent>.Continuation) -> [NSObjectProtocol] {
        let interruption = center.addObserver(forName: AVAudioSession.interruptionNotification,
                                              object: nil, queue: nil) { note in
            guard let typeRaw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue else { return }
            let optionRaw = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            if let event = SessionEventMapper.interruption(typeRaw: typeRaw, optionRaw: optionRaw) {
                continuation.yield(event)
            }
        }
        let route = center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                       object: nil, queue: nil) { note in
            guard let reasonRaw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue else { return }
            if let event = SessionEventMapper.routeChange(reasonRaw: reasonRaw) {
                continuation.yield(event)
            }
        }
        let reset = center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                       object: nil, queue: nil) { _ in
            continuation.yield(.mediaServicesReset)
        }
        return [interruption, route, reset]
    }
}
#endif
