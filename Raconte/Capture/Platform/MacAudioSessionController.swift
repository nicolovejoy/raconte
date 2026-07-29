#if os(macOS)
import Foundation
import AVFoundation

/// macOS has no AVAudioSession. Interruptions/route changes surface as
/// AVAudioEngineConfigurationChangeNotification (device unplug/switch) → `.routeLost`.
final class MacAudioSessionController: AudioSessionController, @unchecked Sendable {
    let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter = .default) {
        self.center = center
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
        self.token = center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                        object: nil, queue: nil) { _ in
            continuation.yield(.routeLost)
        }
    }

    deinit {
        center.removeObserver(token)
        continuation.finish()
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in cont.resume(returning: granted) }
        }
    }

    func activate() async throws {}   // no session to activate on macOS
    func deactivate() {}
}
#endif
