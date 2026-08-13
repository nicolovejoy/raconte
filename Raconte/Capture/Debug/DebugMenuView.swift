#if DEBUG
import SwiftUI

/// Compact debug menu driving design §6 test 9 ("kill at each transition"): arm a
/// state, drive the app into it via the normal Record/Done/Resume UI, wait for the
/// row to show "waiting — gate hit", then either force-quit/app-switcher-kill for a
/// real recovery test, or tap "Kill now" to `fatalError()` immediately.
///
/// Presented from the `DEBUG-HARNESS-MOUNT` marker in `CaptureView` ("Debug" button,
/// DEBUG builds only).
struct DebugMenuView: View {
    private let controller = TransitionBreakpointController.shared

    // Bundle enumeration + a dyld image walk are I/O that can't change
    // within a process lifetime — compute once in `.task`, never inline in
    // `body` (which re-evaluates on every re-render).
    @State private var buildInfo: String?

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

            Section("Build") {
                Text(buildInfo ?? "Build info unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Transition Breakpoints")
        .task {
            if buildInfo == nil {
                buildInfo = BuildStamp.currentBuildDisplayString()
            }
        }
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
