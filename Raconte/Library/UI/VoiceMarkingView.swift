import SwiftUI

/// T7 Mark Voices, issue #56, Task 6 — the explicit "Mark voices" mode (owner ruling:
/// tap a paragraph to flip its voice, drag a range of words to mark it, WYSIWYG, Done
/// exits via the system Back button — same "back-arrow = Done" convention every other
/// mode screen in this app already uses). Thin binding over `VoiceMarkingModel`, per
/// `MarkerCorrectionView`'s own precedent: no logic here beyond gesture wiring, which
/// itself defers its math to `TokenSelection` (pure, unit-tested).
///
/// Three behaviours this view must NOT "fix" — all pinned by Task 4/5 fixtures:
/// 1. Flipping a paragraph into its neighbour's voice merges them into one block on
///    reload (`TranscriptAttribution` breaks paragraphs at voice switches) — `rows`'
///    ids and count can shrink after a gesture, so nothing here assumes either is
///    stable.
/// 2. A paragraph's leading non-placeable text can come back `voice: nil` after a flip
///    — rendered honestly via the `.none` a11y-id suffix, never guessed.
/// 3. `VoiceMarkingModel.open()` sets `state = .loading` on every post-gesture reload.
///    A full-screen `ProgressView` is only shown while `rows` is empty — once rows
///    exist, the screen keeps rendering them through a reload rather than flashing.
struct VoiceMarkingView: View {
    @Bindable var model: VoiceMarkingModel
    let voiceLabels: [String: String]

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .navigationTitle("Mark voices")
        .task { await model.open() }
        .alert("Couldn’t save", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { shown in if !shown { model.acknowledgeError() } }
        )) {
            Button("OK") { model.acknowledgeError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        Text("Marking voices — tap a paragraph to switch its voice, or drag across words")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .padding(.horizontal)
            .padding(.top, 8)
            .accessibilityIdentifier("voiceMarking.header")
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading where model.rows.isEmpty:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading, .ready:
            rowsScrollView
        case .nothingToMark:
            ContentUnavailableView("Nothing to mark yet",
                                   systemImage: "waveform.badge.exclamationmark",
                                   description: Text("This entry has no markers and nothing transcribed."))
                .accessibilityIdentifier("voiceMarking.empty")
        case .unreadable(let reason):
            // Same refusal rationale as the old marker-correction screen: acting
            // against a log we failed to read risks colliding seq values.
            ContentUnavailableView("Markers couldn’t be read",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text("This entry’s marker log could not be read (\(reason)), "
                                                     + "so voices can’t be changed right now."))
                .accessibilityIdentifier("voiceMarking.unreadable")
        }
    }

    private var rowsScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(model.rows) { row in
                    // Review Important 1: `ForEach` diffs by `row.id` alone (the
                    // paragraph's INDEX in this load — see the type doc above), and a
                    // gesture can renumber/resplit paragraphs while leaving some index
                    // occupied by genuinely different content (a merge shifts everything
                    // after it up by one, a split inserts one). Without this, SwiftUI
                    // reuses the SAME `VoiceMarkingParagraphBlock` instance — and its
                    // `@State private var frames` — across that identity collision, so
                    // stale token rects from the OLD content at this index survive into
                    // the new one. A drag hit-testing against a stale rect can then
                    // resolve to a span index that isn't even in the new paragraph,
                    // clamp/widen against the wrong `placeableIDs`, and silently mark
                    // words the drag never crossed — the exact silent-over-mark class
                    // Task 4's `VoiceMarkingPlan` review killed at the plan layer,
                    // reachable again here at the view layer. Keying identity to the
                    // token id LIST (not just the row id) forces SwiftUI to tear down
                    // and rebuild the block — resetting `frames` and every other gesture
                    // `@State` — whenever the actual content at this index changes,
                    // even when the index itself didn't.
                    VoiceMarkingParagraphBlock(row: row, voiceLabels: voiceLabels, model: model)
                        .id(row.tokens.map(\.id))
                }
            }
            .padding()
        }
    }
}

/// One paragraph's gesture surface: a `DragGesture(minimumDistance: 0)` over a
/// `TokenFlowLayout` of its tokens, in the block's OWN named coordinate space so
/// `TokenSelection`'s pure math never has to reason about scroll offset or sibling
/// blocks. A drag that ends where it began is a tap (flip); otherwise it's a range
/// mark, offered through a confirmation dialog.
private struct VoiceMarkingParagraphBlock: View {
    let row: VoiceMarkingModel.ParagraphRow
    let voiceLabels: [String: String]
    let model: VoiceMarkingModel

    /// Captured via `onGeometryChange` on each token, in the block's own coordinate
    /// space — the exact `frames` shape `TokenSelection.tokenIndex` expects.
    @State private var frames: [(id: Int, rect: CGRect)] = []
    @State private var anchorID: Int?
    @State private var currentID: Int?
    @State private var isDragging = false
    @State private var showingConfirm = false
    @State private var pendingRange: ClosedRange<Int>?
    @State private var pendingTarget: String = VoiceDisplay.mainVoice

    private var coordinateSpaceName: String { "voiceMarking.paragraph.\(row.id)" }

    private var placeableIDs: Set<Int> {
        Set(row.tokens.filter(\.isPlaceable).map(\.id))
    }

    /// Only meaningful mid-drag — `nil` once the gesture ends, so the selection tint
    /// disappears the instant the confirmation dialog (or the flip) takes over.
    private var liveRange: ClosedRange<Int>? {
        guard isDragging, let anchorID, let currentID else { return nil }
        return TokenSelection.selectedRange(anchor: anchorID, current: currentID, placeable: placeableIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Same italic/label treatment as the reading view (`EntryDetailView
            // .attributedParagraph`): a label line only when this journal has opted
            // into one for this voice, italic for the main voice regardless.
            if let label = VoiceDisplay.label(forVoice: row.voice, voiceLabels: voiceLabels) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            TokenFlowLayout(horizontalSpacing: 4, verticalSpacing: 6) {
                ForEach(row.tokens) { token in
                    Text(token.text)
                        .font(.system(.body, design: .serif))
                        .italic(VoiceDisplay.isItalic(voice: row.voice))
                        .foregroundStyle(token.isPlaceable ? .primary : .tertiary)
                        .padding(.horizontal, 1)
                        .background((liveRange?.contains(token.id) ?? false)
                                    ? Color.accentColor.opacity(0.25) : Color.clear)
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named(coordinateSpaceName))
                        } action: { newRect in
                            if let index = frames.firstIndex(where: { $0.id == token.id }) {
                                frames[index].rect = newRect
                            } else {
                                frames.append((id: token.id, rect: newRect))
                            }
                        }
                }
            }
        }
        .coordinateSpace(name: coordinateSpaceName)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .confirmationDialog(confirmTitle, isPresented: $showingConfirm, titleVisibility: .visible) {
            Button(confirmTitle) {
                guard let range = pendingRange else { return }
                Task { await model.markRange(first: range.lowerBound, last: range.upperBound, to: pendingTarget) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityIdentifier("voiceMarking.paragraph.\(row.id).\(row.voice ?? "none")")
    }

    private var confirmTitle: String {
        "Mark as \(VoiceDisplay.accessibilityName(forVoice: pendingTarget, voiceLabels: voiceLabels))"
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpaceName))
            .onChanged { value in
                if anchorID == nil {
                    anchorID = TokenSelection.tokenIndex(at: value.startLocation, frames: frames)
                }
                currentID = TokenSelection.tokenIndex(at: value.location, frames: frames)
                isDragging = true
            }
            .onEnded { value in
                let startToken = TokenSelection.tokenIndex(at: value.startLocation, frames: frames)
                let endToken = TokenSelection.tokenIndex(at: value.location, frames: frames)
                isDragging = false
                anchorID = nil
                currentID = nil

                if startToken == endToken {
                    Task { await model.flipParagraph(row.id) }
                    return
                }
                guard let startToken, let endToken,
                      let range = TokenSelection.selectedRange(anchor: startToken, current: endToken,
                                                                placeable: placeableIDs)
                else { return }
                pendingRange = range
                pendingTarget = model.alternativeVoice(forRangeStartingAt: range.lowerBound)
                showingConfirm = true
            }
    }
}
