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

    var head: PendingFramingItem? { items.first }
    var isEmpty: Bool { items.isEmpty }

    mutating func enqueue(_ item: PendingFramingItem) { items.append(item) }
    mutating func enqueue(contentsOf newItems: [PendingFramingItem]) { items.append(contentsOf: newItems) }

    @discardableResult
    mutating func popHead() -> PendingFramingItem? {
        items.isEmpty ? nil : items.removeFirst()
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
                             onCancel: @escaping (PendingFramingItem) -> Void) -> some View {
        #if os(iOS)
        fullScreenCover(item: item) { pending in
            ImageFramingView(data: pending.data, onUse: { onUse(pending, $0) }, onCancel: { onCancel(pending) })
        }
        #else
        sheet(item: item) { pending in
            ImageFramingView(data: pending.data, onUse: { onUse(pending, $0) }, onCancel: { onCancel(pending) })
        }
        #endif
    }
}
