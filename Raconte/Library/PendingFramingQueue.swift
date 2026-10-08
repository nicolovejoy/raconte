import SwiftUI
import UniformTypeIdentifiers

/// One picked or shot image waiting for the framing step (#121).
struct PendingFramingItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let data: Data
    let type: UTType
    let origin: Origin

    /// Which flow this item came from. The sheets' AFTER-`onPick` bookkeeping differs: a
    /// camera shot feeds the #134 tally and stays up; a library batch dismisses when the
    /// last item lands.
    enum Origin: Equatable, Sendable { case camera, library }
}

/// #121: the items a picker sheet still has to run through `ImageFramingView`, head first.
/// Pure so the multi-select sequencing (`PendingFramingQueueTests`) pins without a picker.
struct PendingFramingQueue: Equatable, Sendable {
    private(set) var items: [PendingFramingItem] = []
    /// Items popped by `beginResolving` whose `onPick` verdict has not come back yet.
    private(set) var inFlight = 0
    /// True once a library item has been enqueued since the last `closeLibraryBatch`.
    private var libraryBatchOpen = false
    private var libraryBatchFailed = false

    var head: PendingFramingItem? { items.first }
    var isEmpty: Bool { items.isEmpty }

    mutating func enqueue(_ item: PendingFramingItem) {
        if item.origin == .library { libraryBatchOpen = true }
        items.append(item)
    }
    mutating func enqueue(contentsOf newItems: [PendingFramingItem]) {
        for item in newItems { enqueue(item) }
    }

    @discardableResult
    mutating func popHead() -> PendingFramingItem? {
        items.isEmpty ? nil : items.removeFirst()
    }

    /// Pops the head to be resolved and counts it in flight until `finishResolving`.
    /// The sheets call this (not `popHead`) so a batch is never judged over while an
    /// `onPick` for one of its items is still running.
    mutating func beginResolving() -> PendingFramingItem? {
        guard let item = popHead() else { return nil }
        inFlight += 1
        return item
    }

    /// Records the `onPick` verdict for an item taken by `beginResolving`.
    mutating func finishResolving(_ item: PendingFramingItem, landed: Bool) {
        inFlight = max(0, inFlight - 1)
        // While a library batch is open, a failure of EITHER origin must survive to the close.
        if libraryBatchOpen && !landed { libraryBatchFailed = true }
    }

    /// A library item whose bytes could not even be loaded, in a batch that has other items.
    mutating func recordLibraryLoadFailure() { libraryBatchFailed = true }

    /// True only when a library batch is open, nothing of ANY origin is still queued (a
    /// queued camera shot has no other copy), and no `onPick` is in flight.
    var libraryBatchIsOver: Bool { libraryBatchOpen && items.isEmpty && inFlight == 0 }

    /// Ends the batch: returns whether any of its items failed, then resets.
    mutating func closeLibraryBatch() -> Bool {
        defer { libraryBatchOpen = false; libraryBatchFailed = false }
        return libraryBatchFailed
    }

    /// What reaches `onPick` for `item` under `framing`. Identity hands the original bytes
    /// and declared type through untouched — an uncropped PNG/HEIC pick is never silently
    /// re-encoded. A non-identity framing hands the framed JPEG, or, if `apply` fails, the
    /// original: the crop step is best-effort; the owner's photo is not.
    static func resolve(_ item: PendingFramingItem, framing: ImageFraming) -> (Data, UTType) {
        guard !framing.isIdentity else { return (item.data, item.type) }
        guard let framed = framing.apply(to: item.data) else { return (item.data, item.type) }
        return (framed, .jpeg)
    }
}

extension PendingFramingQueue {
    /// A binding to the head for `.fullScreenCover(item:)`/`.sheet(item:)`: setting it to nil
    /// (the system dismissing the cover) is a no-op — the sheets pop the head themselves in
    /// Use/Cancel so the dismissal never races the resolution.
    var headBinding: PendingFramingItem? {
        get { head }
        set { }
    }
}

extension View {
    /// #121: presents `ImageFramingView` for the queue head — `.fullScreenCover` on iOS,
    /// `.sheet` on macOS — attached to the OUTER view of the presenting sheet (never a
    /// `Section`; CLAUDE.md). `onUse`/`onCancel` receive the item so the presenter resolves
    /// exactly what was shown, never "whatever the head is now" (CLAUDE.md: capture the id
    /// when the intent is armed, never a `.last` later).
    func framingPresentation(item: Binding<PendingFramingItem?>,
                             onUse: @escaping (PendingFramingItem, ImageFraming) -> Void,
                             onCancel: @escaping (PendingFramingItem) -> Void,
                             onDismiss: @escaping () -> Void) -> some View {
        #if os(iOS)
        fullScreenCover(item: item, onDismiss: onDismiss) { pending in
            ImageFramingView(data: pending.data, onUse: { onUse(pending, $0) }, onCancel: { onCancel(pending) })
                .id(pending.id)  // an item swap keeps the cover's @State otherwise
        }
        #else
        sheet(item: item, onDismiss: onDismiss) { pending in
            ImageFramingView(data: pending.data, onUse: { onUse(pending, $0) }, onCancel: { onCancel(pending) })
                .id(pending.id)  // an item swap keeps the cover's @State otherwise
        }
        #endif
    }
}
