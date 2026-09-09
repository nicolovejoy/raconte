import Foundation

/// The app-wide "ink & paper" palette as pure channel values, extending the
/// `CaptureSurface` idea (constant surface ⇒ checkable contrast) to the reading
/// surfaces. Light values are the design's committed hex values
/// (spec: docs/plans/2026-08-29-ux-redesign-design.md, retuned for #149 in
/// docs/plans/2026-09-08-design-system-type-and-ink.md batch 2). Dark counterparts live
/// here too — both are pure numbers; only `color` (SwiftUI) is in `InkSurface+SwiftUI.swift`.
enum InkTone: CaseIterable, Sendable {
    /// Reading background — warm white.
    case paper
    /// Inset ground: sheets, the pinned play bar.
    case paperInset
    /// Dividers.
    case hairline
    /// Primary text.
    case ink
    /// Secondary text — row second lines, dates, metadata. READ text, so it clears the
    /// 4.5:1 normal-text floor on both paper grounds (#149; the earlier #8B8478 measured
    /// 3.37:1 on paper and 3.14:1 on paperInset, and is now `inkDisabled`).
    case inkSecondary
    /// Disabled / placeholder text — an unplaceable voice token, the approximate-boundary
    /// mark. Readable (≥ 3.0:1) but visibly weaker than `inkSecondary` (≥ 1.3:1 apart).
    case inkDisabled
    /// Warm amber — links, active states, scrubber fill.
    case accent
    /// The app's one loud colour; shared with capture's record button.
    case record
    /// #161: a marker that must be seen — the out-of-span glyph, the quarantine block's
    /// bar. Darkened safety orange (#D2570A, ~3.7:1 on paper, ~3.5:1 on paperInset); lightens
    /// on dark paper.
    case warning
    /// The capture screen's fixed near-black. Pinned to `CaptureSurface.backgroundWhite`.
    case studio
    /// Text on the studio ground — the capture screen's full white (#118 §8; was a
    /// `.white` literal in `CaptureView`).
    case studioInk
    /// The live transcript's provisional text (#118 §5): readable, unmistakably weaker
    /// than `studioInk`. Clears the 7.0:1 capture floor with a little to spare.
    case studioInkDim
    /// The receipt card's ground on studio (#118 §3).
    case studioCard
    /// The receipt card's border on studio.
    case studioHairline
    /// The "Saved" chip's ground — system green at 22%, flattened to a constant so it
    /// can be checked. Actually drawn over `studioCard`, not `studio` directly; the two
    /// grounds are close enough (`.grey(0.11)` vs. the near-black studio background)
    /// that the difference is visually negligible.
    case studioSaved

    var lightColor: CaptureLabelColor {
        switch self {
        case .paper: CaptureLabelColor(red: 0xF7 / 255, green: 0xF4 / 255, blue: 0xEE / 255)
        case .paperInset: CaptureLabelColor(red: 0xF0 / 255, green: 0xEC / 255, blue: 0xE3 / 255)
        case .hairline: CaptureLabelColor(red: 0xE5 / 255, green: 0xDF / 255, blue: 0xD4 / 255)
        case .ink: CaptureLabelColor(red: 0x21 / 255, green: 0x1D / 255, blue: 0x18 / 255)
        // #149: 5.02:1 on paper, 4.67:1 on paperInset.
        case .inkSecondary: CaptureLabelColor(red: 0x6F / 255, green: 0x68 / 255, blue: 0x5D / 255)
        // #149: the former inkSecondary — 3.37:1 on paper, 3.14:1 on paperInset, 1.49:1
        // weaker than the new inkSecondary.
        case .inkDisabled: CaptureLabelColor(red: 0x8B / 255, green: 0x84 / 255, blue: 0x78 / 255)
        // Darkened from the spec's #96683A (4.41:1 on paper — fails the 4.5 AA floor by a
        // hair) to #916438 (4.63:1). Adjustment per task-1 brief NOTE: darken a failing
        // tone rather than lower the floor.
        case .accent: CaptureLabelColor(red: 0x91 / 255, green: 0x64 / 255, blue: 0x38 / 255)
        case .record: CaptureLabelColor(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255)
        case .warning: CaptureLabelColor(red: 0xD2 / 255, green: 0x57 / 255, blue: 0x0A / 255)
        case .studio: .grey(CaptureSurface.backgroundWhite)
        case .studioInk: .grey(1.0)
        case .studioInkDim: .grey(0.62)
        case .studioCard: .grey(0.11)
        case .studioHairline: .grey(0.17)
        case .studioSaved: CaptureLabelColor(red: 0.08, green: 0.21, blue: 0.12)
        }
    }

    /// Dark-appearance channel values. Paper family inverts to warm near-blacks;
    /// text inverts to warm off-whites; accent lightens to keep contrast on dark
    /// paper; record and studio are appearance-invariant.
    var darkColor: CaptureLabelColor {
        switch self {
        case .paper: CaptureLabelColor(red: 0x16 / 255, green: 0x14 / 255, blue: 0x11 / 255)
        case .paperInset: CaptureLabelColor(red: 0x1F / 255, green: 0x1C / 255, blue: 0x18 / 255)
        case .hairline: CaptureLabelColor(red: 0x2E / 255, green: 0x2A / 255, blue: 0x24 / 255)
        case .ink: CaptureLabelColor(red: 0xEC / 255, green: 0xE8 / 255, blue: 0xE0 / 255)
        // 6.04:1 on dark paper, 5.57:1 on dark paperInset.
        case .inkSecondary: CaptureLabelColor(red: 0x9A / 255, green: 0x93 / 255, blue: 0x87 / 255)
        // #149: 3.59:1 on dark paper, 3.32:1 on dark paperInset, 1.68:1 weaker than secondary.
        case .inkDisabled: CaptureLabelColor(red: 0x73 / 255, green: 0x6D / 255, blue: 0x65 / 255)
        case .accent: CaptureLabelColor(red: 0xC8 / 255, green: 0x93 / 255, blue: 0x5E / 255)
        case .warning: CaptureLabelColor(red: 0xFF / 255, green: 0x8A / 255, blue: 0x2A / 255)
        case .record, .studio, .studioInk, .studioInkDim, .studioCard, .studioHairline, .studioSaved: lightColor
        }
    }

    /// Channel values for one appearance. Not named `color` — that is the SwiftUI property.
    func channels(for appearance: InkAppearance) -> CaptureLabelColor {
        switch appearance {
        case .light: lightColor
        case .dark: darkColor
        }
    }
}

/// The two appearances the reading surfaces follow. A pure value so the floor table can be
/// checked for both from one test run (the studio surface ignores this — it is pinned dark).
enum InkAppearance: CaseIterable, Sendable {
    case light
    case dark
}

enum InkSurface {
    /// WCAG 2.1 contrast of a tone against a ground tone, in one appearance. Luminance is
    /// `CaptureSurface.relativeLuminance(_:)` — not reimplemented here, so the two surfaces
    /// can never drift apart on the underlying formula.
    static func contrast(_ tone: InkTone, on surface: InkTone, appearance: InkAppearance) -> Double {
        let a = CaptureSurface.relativeLuminance(tone.channels(for: appearance))
        let b = CaptureSurface.relativeLuminance(surface.channels(for: appearance))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Contrast of a raw colour against light-mode paper — the original, kept for the
    /// existing tests; `contrast(_:on:appearance:)` is the general form.
    static func contrastOnPaper(_ color: CaptureLabelColor) -> Double {
        let a = CaptureSurface.relativeLuminance(color)
        let b = CaptureSurface.relativeLuminance(InkTone.paper.lightColor)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Spec batch 2 (#149): the floor each text-bearing tone must clear on `paper` AND
    /// `paperInset`, light AND dark. 4.5 is WCAG AA for normal text; 3.0 is AA for large
    /// text and graphical objects (disabled text, glyphs, the warning marker).
    static let textFloors: [(tone: InkTone, floor: Double)] = [
        (.ink, 4.5),
        (.inkSecondary, 4.5),
        (.inkDisabled, 3.0),
        (.accent, 3.0),
        (.warning, 3.0),
    ]
}
