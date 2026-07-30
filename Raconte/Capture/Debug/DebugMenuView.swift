#if DEBUG
import SwiftUI

/// Compact debug menu driving design §6 test 9 ("kill at each transition"): arm a
/// state, drive the app into it via the normal Record/Done/Resume UI, wait for the
/// row to show "waiting — gate hit", then either force-quit/app-switcher-kill for a
/// real recovery test, or tap "Kill now" to `fatalError()` immediately.
///
/// Not mounted anywhere yet — the app shell (owned by a concurrent agent) presents
/// it, e.g. from a `// DEBUG-HARNESS-MOUNT` marker: a debug-only toolbar
/// item/gesture that pushes `DebugMenuView()` (`#if DEBUG`-guarded).
struct DebugMenuView: View {
    private let controller = TransitionBreakpointController.shared

    var body: some View {
        List {
            Section("Kill switch") {
                Button(role: .destructive) {
                    controller.abort()
                } label: {
                    Label("Kill now", systemImage: "bolt.trianglebadge.exclamationmark.fill")
                }
                .disabled(controller.waitingStates.isEmpty)
            }

            Section("Arm a transition") {
                ForEach(CaptureState.allCases, id: \.self) { state in
                    row(for: state)
                }
            }

            Section {
                Button("Disarm all", role: .cancel) { controller.disarmAll() }
                    .disabled(controller.armedStates.isEmpty)
            }
        }
        .navigationTitle("Transition Breakpoints")
    }

    @ViewBuilder
    private func row(for state: CaptureState) -> some View {
        let armed = controller.isArmed(state)
        let waiting = controller.isWaiting(state)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.rawValue).font(.body.monospaced())
                if waiting {
                    Text("waiting — gate hit").font(.caption).foregroundStyle(.orange)
                } else if armed {
                    Text("armed").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { armed },
                set: { isOn in isOn ? controller.arm(state) : controller.disarm(state) }
            ))
            .labelsHidden()
        }
    }
}

#Preview {
    NavigationStack { DebugMenuView() }
}
#endif
