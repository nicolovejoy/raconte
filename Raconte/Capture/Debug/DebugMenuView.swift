#if DEBUG
import SwiftUI

/// Debug place (nav T7): build info sits at the top of the list — the row the owner
/// actually visits — with the transition-breakpoint harness fenced below it under an
/// explicit "can wedge or kill the app" section. The fencing is presentational only;
/// none of the harness rows are functionally gated by it, since this whole screen is
/// DEBUG-only.
///
/// Drives design §6 test 9 ("kill at each transition"): arm a state, drive the app
/// into it via the normal Record/Done/Resume UI, wait for the row to show
/// "waiting — gate hit", then either force-quit/app-switcher-kill for a real recovery
/// test, or tap "Kill now" to SIGKILL the process immediately (`abort()` — see
/// `TransitionBreakpoints.swift`, deliberately not `fatalError()`).
///
/// Routed from the sidebar's Debug place (`ContentView.detailRoot`, DEBUG builds
/// only) since nav T5/T6 retired the old toolbar-button/sheet presentation.
struct DebugMenuView: View {
    private let controller = TransitionBreakpointController.shared

    // Bundle enumeration + a dyld image walk are I/O that can't change
    // within a process lifetime — compute once in `.task`, never inline in
    // `body` (which re-evaluates on every re-render).
    @State private var buildInfo: String?

    var body: some View {
        List {
            // Design §6 (nav T7): build info promoted to the top — it is the row the
            // owner actually visits. The harness (below) is fenced under its own
            // section, presentationally only; nothing here is functionally gated.
            Section("Build") {
                Text(buildInfo ?? "Build info unavailable")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("debug.buildInfo")
            }

            Section {
                Button(role: .destructive) {
                    controller.abort()
                } label: {
                    Label("Kill now", systemImage: "bolt.trianglebadge.exclamationmark.fill")
                }
                .disabled(controller.waitingStates.isEmpty)
                .accessibilityIdentifier("debug.killNow")

                ForEach(CaptureState.allCases, id: \.self) { state in
                    row(for: state)
                        .accessibilityIdentifier("debug.row.\(state.rawValue)")
                }

                Button("Disarm all", role: .cancel) { controller.disarmAll() }
                    .disabled(controller.armedStates.isEmpty)
                    .accessibilityIdentifier("debug.disarmAll")
            } header: {
                Text("Harness — can wedge or kill the app")
            } footer: {
                Text("Arming a transition pauses the app when it reaches that state. "
                     + "Kill now kills the app process immediately.")
            }
        }
        .navigationTitle("Debug")
        .accessibilityIdentifier("debug.list")
        .task {
            if buildInfo == nil {
                buildInfo = await BuildStamp.currentBuildDisplayStringAsync()
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
