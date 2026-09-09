import SwiftUI

/// SwiftUI half of `InkTone` — the model stays pure Foundation (CaptureSurface split).
/// Dark mode: reading surfaces follow the system appearance, so each tone carries a
/// dark counterpart (both live in `InkSurface.swift` next to the light values) and
/// resolves through a dynamic Color here. Capture surfaces keep using
/// `.studio` + pinned `.dark` colour scheme exactly as today.
extension InkTone {
    var color: Color {
        #if os(iOS)
        Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? darkColor : lightColor
            return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
        })
        #else
        Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? darkColor : lightColor
            return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
        })
        #endif
    }
}
