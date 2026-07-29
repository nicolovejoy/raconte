import Foundation

enum SessionEvent: Sendable, Equatable {
    case interrupted
    case resumeAvailable(shouldResume: Bool)
    case routeLost
    case mediaServicesReset
}

protocol AudioSessionController: Sendable {
    func requestPermission() async -> Bool
    func activate() async throws
    func deactivate()
    var events: AsyncStream<SessionEvent> { get }
}

/// Pure translation of notification payload raw values to `SessionEvent`.
/// Kept free of AVFAudio types so the iOS mapping is testable on macOS (where
/// AVAudioSession is API_UNAVAILABLE). Raw values are from AVAudioSessionTypes.h.
enum SessionEventMapper {
    static let interruptionOptionShouldResume: UInt = 1   // AVAudioSessionInterruptionOptionShouldResume
    static let routeChangeOldDeviceUnavailable: UInt = 2  // AVAudioSessionRouteChangeReasonOldDeviceUnavailable

    // AVAudioSessionInterruptionType: Began = 1, Ended = 0.
    static func interruption(typeRaw: UInt, optionRaw: UInt) -> SessionEvent? {
        switch typeRaw {
        case 1: return .interrupted
        case 0: return .resumeAvailable(shouldResume: optionRaw & interruptionOptionShouldResume != 0)
        default: return nil
        }
    }

    static func routeChange(reasonRaw: UInt) -> SessionEvent? {
        reasonRaw == routeChangeOldDeviceUnavailable ? .routeLost : nil
    }
}
