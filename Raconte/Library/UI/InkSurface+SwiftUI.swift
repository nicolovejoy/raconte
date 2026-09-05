import SwiftUI

/// SwiftUI half of `InkTone` — the model stays pure Foundation (CaptureSurface split).
/// Dark mode: reading surfaces follow the system appearance, so each tone carries a
/// dark counterpart and resolves through a dynamic Color. Capture surfaces keep using
/// `.studio` + pinned `.dark` colour scheme exactly as today.
extension InkTone {
    /// Dark-appearance channel values. Paper family inverts to warm near-blacks;
    /// text inverts to warm off-whites; accent lightens to keep contrast on dark
    /// paper; record and studio are appearance-invariant.
    var darkColor: CaptureLabelColor {
        switch self {
        case .paper: CaptureLabelColor(red: 0x16 / 255, green: 0x14 / 255, blue: 0x11 / 255)
        case .paperInset: CaptureLabelColor(red: 0x1F / 255, green: 0x1C / 255, blue: 0x18 / 255)
        case .hairline: CaptureLabelColor(red: 0x2E / 255, green: 0x2A / 255, blue: 0x24 / 255)
        case .ink: CaptureLabelColor(red: 0xEC / 255, green: 0xE8 / 255, blue: 0xE0 / 255)
        case .inkSecondary: CaptureLabelColor(red: 0x9A / 255, green: 0x93 / 255, blue: 0x87 / 255)
        case .accent: CaptureLabelColor(red: 0xC8 / 255, green: 0x93 / 255, blue: 0x5E / 255)
        case .record, .studio, .studioInk, .studioInkDim, .studioCard, .studioHairline, .studioSaved: lightColor
        }
    }

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
