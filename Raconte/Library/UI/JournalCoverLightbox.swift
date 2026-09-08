import SwiftUI

/// #106: a journal's cover at the largest size we have. Covers are stored once, downscaled to
/// 1024 px on the long side (`JournalCoverStore`), so this is that JPEG scaled to fit — there
/// is no larger original, unlike entry images. Presented full-screen on iOS and as a large
/// sheet on macOS (`fullScreenCover` does not exist there), always from the editor `Form`'s
/// own modifier chain. Dismiss: Done, Esc (macOS, via the cancel keyboard shortcut), or a
/// tap anywhere on the image's ground.
struct JournalCoverLightbox: View {
    let data: Data
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = JournalCoverThumbnail.decode(data) {
                    image
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    Text("This cover could not be decoded.")
                        .foregroundStyle(.white)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }
            .accessibilityIdentifier("journalCover.lightbox")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("journalCover.lightbox.done")
                }
            }
            #if os(macOS)
            .frame(minWidth: 720, minHeight: 540)
            #endif
        }
    }
}
