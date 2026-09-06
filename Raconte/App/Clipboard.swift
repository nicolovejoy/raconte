import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The one clipboard write in the app (#105). Platform-split here so no view carries an
/// `#if` for it.
enum Clipboard {
    @MainActor
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        #error("Clipboard.copy has no implementation for this platform")
        #endif
    }
}
