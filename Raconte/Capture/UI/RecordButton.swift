import SwiftUI

/// Semantic tint for the capture control, honoring the affordance rule carried over
/// from the web app: **red == capturing only**. Connecting/preparing/resuming/stopping
/// are neutral ("don't speak yet"); interrupted is a blinking red.
enum RecordControlTint: Equatable, Sendable {
    /// Idle invitation to record — neutral, never red.
    case idle
    /// Audio is flowing. Solid red.
    case capturing
    /// Working, don't speak yet (preparing / resuming / stopping / finalizing).
    case neutral
    /// Interrupted / paused. Blinking red.
    case interrupted
    /// Nothing to do (a finished/terminal phase before the screen resets).
    case done
}

/// Pure mapping from the machine `CaptureState` (+ whether a manual Resume is offered)
/// to the big round control's appearance and primary action. No SwiftUI, no I/O — this
/// is the unit-tested core of the capture UI (design §6).
struct RecordControlModel: Equatable, Sendable {
    enum Action: Equatable, Sendable { case record, done, resume, none }

    var action: Action
    var systemImage: String
    var tint: RecordControlTint
    var isBlinking: Bool
    var isEnabled: Bool
    var label: String

    /// Whether a secondary "Done" button should accompany the primary control
    /// (offered while interrupted so a stalled capture can be committed — §2 row 14).
    var showsDoneButton: Bool

    static func make(phase: CaptureState, canResume: Bool) -> RecordControlModel {
        switch phase {
        case .idle:
            return .init(action: .record, systemImage: "mic.fill", tint: .idle,
                         isBlinking: false, isEnabled: true, label: "Record",
                         showsDoneButton: false)
        case .preparing:
            return .init(action: .none, systemImage: "hourglass", tint: .neutral,
                         isBlinking: false, isEnabled: false, label: "Preparing…",
                         showsDoneButton: false)
        case .recording:
            return .init(action: .done, systemImage: "stop.fill", tint: .capturing,
                         isBlinking: false, isEnabled: true, label: "Stop",
                         showsDoneButton: false)
        case .interrupted:
            return .init(action: canResume ? .resume : .none,
                         systemImage: canResume ? "play.fill" : "pause.fill",
                         tint: .interrupted, isBlinking: true,
                         isEnabled: canResume, label: canResume ? "Resume" : "Interrupted",
                         showsDoneButton: true)
        case .resuming:
            return .init(action: .none, systemImage: "hourglass", tint: .neutral,
                         isBlinking: false, isEnabled: false, label: "Resuming…",
                         showsDoneButton: false)
        case .stopping:
            return .init(action: .none, systemImage: "stop.fill", tint: .neutral,
                         isBlinking: false, isEnabled: false, label: "Saving…",
                         showsDoneButton: false)
        case .finalizing:
            return .init(action: .none, systemImage: "hourglass", tint: .neutral,
                         isBlinking: false, isEnabled: false, label: "Finalizing…",
                         showsDoneButton: false)
        case .captured, .complete:
            return .init(action: .none, systemImage: "checkmark", tint: .done,
                         isBlinking: false, isEnabled: false, label: "Saved",
                         showsDoneButton: false)
        }
    }
}

extension RecordControlTint {
    /// The fill color for the control. Kept out of the pure model so the palette can
    /// evolve (Milestone 5) without touching tested logic.
    var color: Color {
        switch self {
        case .idle: return Color(white: 0.92)
        case .capturing, .interrupted: return .red
        case .neutral: return Color(white: 0.35)
        case .done: return .green
        }
    }

    var foreground: Color {
        switch self {
        case .idle: return .black
        default: return .white
        }
    }
}

/// The one big round capture control. Appearance + action come from `RecordControlModel`;
/// the blinking-red interrupted state animates opacity.
struct RecordButton: View {
    let model: RecordControlModel
    let action: () -> Void

    @State private var blinkOn = true

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(model.tint.color)
                    .opacity(model.isBlinking && !blinkOn ? 0.35 : 1)
                Image(systemName: model.systemImage)
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(model.tint.foreground)
            }
            .frame(width: 132, height: 132)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 2))
            .shadow(color: model.tint.color.opacity(0.4), radius: model.isBlinking ? 18 : 8)
        }
        .buttonStyle(.plain)
        .disabled(!model.isEnabled)
        .opacity(model.isEnabled ? 1 : 0.65)
        .accessibilityLabel(model.label)
        .onChange(of: model.isBlinking) { _, blinking in
            blinkOn = true
            if blinking { startBlink() }
        }
        .onAppear { if model.isBlinking { startBlink() } }
    }

    private func startBlink() {
        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
            blinkOn = false
        }
    }
}
