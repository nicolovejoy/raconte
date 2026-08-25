import Foundation
import UniformTypeIdentifiers

/// The shared data-extraction step behind macOS drag-and-drop (`.onDrop` on the entry
/// detail screen and each library row, `LibraryEntryRow`) and paste (`.onPasteCommand`,
/// entry detail screen only) — image capture plan Task 9. SwiftUI hands both mechanisms
/// the same `[NSItemProvider]` shape, so one function serves both call sites; each then
/// feeds the result straight into `LibraryScreenModel.addImage(_:data:sourceUTType:)`,
/// the SAME method `ImageCapturePickerSheet`'s `onPick` closure already terminates at
/// (Task 6's picker-driven add flow) — there is no second image-add code path, only a
/// second way to arrive at the data this function hands to it.
///
/// `@MainActor`, not a free-floating `nonisolated` function: `NSItemProvider` is not
/// `Sendable`, and every call site (`EntryDetailView`, `LibraryEntryRow`) is itself
/// `@MainActor` SwiftUI view code — pinning this type to the same actor keeps the
/// `[NSItemProvider]` argument on the actor it was already isolated to instead of
/// "sending" it across an isolation boundary, which is what Swift 6 strict concurrency
/// flags as a data-race risk for a non-Sendable type.
@MainActor
enum ImageDropSource {
    /// The first provider that can supply image bytes, loaded as `(Data, UTType)`. A
    /// provider commonly advertises several conforming type identifiers (e.g.
    /// `public.jpeg` alongside the generic `public.image`); this keeps the first one
    /// that actually conforms to `.image`, which is the concrete type `ImageStore
    /// .addImage`'s `sourceUTType` wants — see `ImageCapturePickerSheet`'s doc comment
    /// on why bytes alone aren't enough for that call. Returns `nil` when no provider
    /// in the list offers an image representation, or the load itself fails (the
    /// pasteboard/drag item was something else, or the load was cancelled) — the two
    /// callers surface that as "couldn't use that photo", the same failure copy the
    /// picker sheet already shows for its own decode failures.
    static func extract(from providers: [NSItemProvider]) async -> (data: Data, type: UTType)? {
        for provider in providers {
            guard let typeIdentifier = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .image) ?? false
            }) else { continue }
            if let data = await loadDataRepresentation(provider, typeIdentifier: typeIdentifier),
               let type = UTType(typeIdentifier) {
                return (data, type)
            }
        }
        return nil
    }

    private static func loadDataRepresentation(_ provider: NSItemProvider,
                                                typeIdentifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
