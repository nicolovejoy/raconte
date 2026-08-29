import Foundation

/// The app-wide "ink & paper" palette as pure channel values, extending the
/// `CaptureSurface` idea (constant surface ⇒ checkable contrast) to the reading
/// surfaces. Light values here are the design's committed hex values
/// (spec: docs/plans/2026-08-29-ux-redesign-design.md); dark-mode counterparts live in
/// `InkSurface+SwiftUI.swift` because they ride SwiftUI's appearance system.
enum InkTone: CaseIterable, Sendable {
    /// Reading background — warm white.
    case paper
    /// Inset ground: sheets, the pinned play bar.
    case paperInset
    /// Dividers.
    case hairline
    /// Primary text.
    case ink
    /// Secondary text.
    case inkSecondary
    /// Warm amber — links, active states, scrubber fill.
    case accent
    /// The app's one loud colour; shared with capture's record button.
    case record
    /// The capture screen's fixed near-black. Pinned to `CaptureSurface.backgroundWhite`.
    case studio

    var lightColor: CaptureLabelColor {
        switch self {
        case .paper: CaptureLabelColor(red: 0xF7 / 255, green: 0xF4 / 255, blue: 0xEE / 255)
        case .paperInset: CaptureLabelColor(red: 0xF0 / 255, green: 0xEC / 255, blue: 0xE3 / 255)
        case .hairline: CaptureLabelColor(red: 0xE5 / 255, green: 0xDF / 255, blue: 0xD4 / 255)
        case .ink: CaptureLabelColor(red: 0x21 / 255, green: 0x1D / 255, blue: 0x18 / 255)
        case .inkSecondary: CaptureLabelColor(red: 0x8B / 255, green: 0x84 / 255, blue: 0x78 / 255)
        // Darkened from the spec's #96683A (4.41:1 on paper — fails the 4.5 AA floor by a
        // hair) to #916438 (4.63:1). Adjustment per task-1 brief NOTE: darken a failing
        // tone rather than lower the floor.
        case .accent: CaptureLabelColor(red: 0x91 / 255, green: 0x64 / 255, blue: 0x38 / 255)
        case .record: CaptureLabelColor(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255)
        case .studio: .grey(CaptureSurface.backgroundWhite)
        }
    }
}

enum InkSurface {
    /// Contrast of a tone against light-mode paper — same WCAG 2.1 math as
    /// `CaptureSurface.contrastOnSurface`, different ground. Luminance itself is
    /// `CaptureSurface.relativeLuminance(_:)` — not reimplemented here, so the two
    /// surfaces can never drift apart on the underlying formula.
    static func contrastOnPaper(_ color: CaptureLabelColor) -> Double {
        let a = CaptureSurface.relativeLuminance(color)
        let b = CaptureSurface.relativeLuminance(InkTone.paper.lightColor)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
