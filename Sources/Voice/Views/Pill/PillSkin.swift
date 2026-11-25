import SwiftUI
import AppKit

// MARK: - Pill skin
//
// A skin is data: colours, how the body is rendered (a flat plate, or glass that refracts what
// is behind it), sizes, type, waveform and motion. Pill views never hard-code a look; they read
// `@Environment(\.pillSkin)`. A new skin is one more `static let` below plus an entry in
// `PillSkin.all`.
//
// The `pillSkin` default picks the skin: "default", "glassLight", "glassDark". Older values
// ("glass", "black", "niche") mean Default.

struct PillSkin: Identifiable, Equatable {
    /// The stored `pillSkin` value.
    let id: String
    /// What the settings show.
    let name: String
    var palette: Palette
    var surface: Surface
    var renderer: Renderer
    var metrics: Metrics
    var type: TypeScale
    var waveform: Waveform
    var motion: Motion
    /// Set by `adapted(toBackdropLuma:)`: light glass over a bright screen, so ink is dark and
    /// anything drawn in white or pale tints has to flip too.
    var onBrightGlass = false

    /// How the body is drawn. Both run the same metaball shape (PillShaders.metal).
    enum Renderer: Equatable {
        /// A flat plate: `surface.fill`, one thin edge, soft shadow.
        case plate
        /// Glass over a live capture of what is behind the pill.
        case glass(Glass)
    }

    struct Glass: Equatable {
        /// Tint mixed into the refracted picture (alpha = how much).
        var tint: Color
        /// Rim and specular light.
        var rim: Color
        /// How far in from the edge the bevel reaches, in points.
        var bevel: CGFloat
        /// How far the bevel bends the picture, in points.
        var refraction: CGFloat
        /// Colour fringe at the rim, in points.
        var dispersion: CGFloat
        /// Frost: spread of the blur taps, in points.
        var frost: CGFloat
        /// 0...1: how much the middle magnifies.
        var magnify: CGFloat
        /// 0...1: how much of the colour behind survives (glass is nearly colourless).
        var saturation: CGFloat
        /// Dark glass gathers light toward the top and shades the lower rim more.
        var dark: Bool
        /// Light glass flips its ink to dark over a bright background.
        var adaptiveInk: Bool
        /// Where there is no capture (no Screen Recording permission): a blur behind instead.
        var fallbackTint: Color
    }

    /// Colours. Mono: one ink on the body, one tint for errors.
    struct Palette: Equatable {
        var ink: Color
        var inkSecondary: Color
        var inkFaint: Color
        var danger: Color
        var warning: Color
        /// Meeting notes are recording.
        var live: Color
        var controlFill: Color
        var controlInk: Color
        var confirmFill: Color
        var confirmInk: Color
        var buttonFill: Color
        var buttonFillHover: Color
        var buttonInk: Color
        var ringTrack: Color
        var ringProgress: Color
        /// The progress light that runs through the body.
        var light: Color
        var dragDim: Color
        var dragZone: Color
        var dragZoneActive: Color
    }

    /// The plate (flat skins) and what every skin shares: edge, shadow, corners.
    struct Surface: Equatable {
        enum Corners: Equatable {
            case capsule
            case rounded(CGFloat)
        }
        var corners: Corners
        var fill: Color
        var restingFill: Color
        var restingEdge: Color
        var edge: Color
        var edgeHover: Color
        var edgeWidth: CGFloat
        var shadow: Color
        var shadowRadius: CGFloat
        var shadowY: CGFloat
        var cardCornerRadius: CGFloat
    }

    /// Sizes along the bottom edge (length x thickness).
    struct Metrics: Equatable {
        var thickness: CGFloat
        var resting: CGSize
        var restingCornerRadius: CGFloat
        var readyLength: CGFloat
        /// The wand's options tab beside its circle.
        var readyOptions: CGFloat
        /// Pieces that bud off the body: their size, the gap they settle at, and the blend
        /// radius of the metaball field (larger melts them together more).
        var budSize: CGFloat
        var budGap: CGFloat
        var blend: CGFloat
        var pushToTalkLength: CGFloat
        var handsFreeLength: CGFloat
        var thinkingLength: CGFloat
        var errorLength: CGFloat
        var meetingLength: CGFloat
        var statusPadding: CGFloat
        var statusGap: CGFloat
        var polishLength: CGFloat
        var controlDiameter: CGFloat
        var controlGap: CGFloat
        var pickerSize: CGFloat
        var pickerGap: CGFloat
        var noticePadding: CGFloat
        var noticeMaxWidth: CGFloat
        var noticeIcon: CGFloat
        var cardPadding: CGFloat
        var cardMinWidth: CGFloat
        var cardMaxWidth: CGFloat
        var tooltipPadding: CGFloat
        var tooltipHeight: CGFloat
        var micGlyph: CGFloat
    }

    struct TypeScale: Equatable {
        enum Family: Equatable { case figtree, system }
        enum Role { case label, caption, title, body, button, tooltip, tooltipKey }
        var family: Family
        var labelSize: CGFloat
        var captionSize: CGFloat
        var titleSize: CGFloat
        var bodySize: CGFloat
        var tooltipSize: CGFloat

        private func spec(_ role: Role) -> (CGFloat, Font.Weight) {
            switch role {
            case .label: return (labelSize, .semibold)
            case .caption: return (captionSize, .medium)
            case .title: return (titleSize, .semibold)
            case .body: return (bodySize, .regular)
            case .button: return (labelSize, .semibold)
            case .tooltip: return (tooltipSize, .medium)
            case .tooltipKey: return (tooltipSize, .bold)
            }
        }

        func font(_ role: Role) -> Font {
            let (size, weight) = spec(role)
            switch family {
            case .figtree: return .flowBar(size, weight: weight)
            case .system: return .system(size: size, weight: weight)
            }
        }

        /// For measuring text (sizes are decided before the content appears). Main thread.
        func nsFont(_ role: Role) -> NSFont {
            let (size, weight) = spec(role)
            if family == .figtree, let font = Font.flowBarNSFont(size, weight: weight) { return font }
            let ns: NSFont.Weight = weight == .semibold ? .semibold : weight == .bold ? .bold : weight == .medium ? .medium : .regular
            return NSFont.systemFont(ofSize: size, weight: ns)
        }
    }

    struct Waveform: Equatable {
        var barCount: Int
        var meetingBarCount: Int
        var barWidth: CGFloat
        var barPitch: CGFloat
        var restLength: CGFloat
        var gain: Double
        var roundEnds: Bool
        /// How much the travelling wave moves (0 = still).
        var wave: Double

        var length: CGFloat { CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * (barPitch - barWidth) }
        var meetingLength: CGFloat { CGFloat(meetingBarCount) * barWidth + CGFloat(meetingBarCount - 1) * (barPitch - barWidth) }
    }

    /// Springs for shape changes, and the small timings around them.
    struct Motion: Equatable {
        struct Spring: Equatable {
            var response: Double
            var damping: Double
            var animation: Animation { .spring(response: response, dampingFraction: damping) }
        }
        /// Out of rest into capture: quick, so the hotkey feels instant.
        var quick: Spring
        /// Any change while working.
        var morph: Spring
        /// Back to rest.
        var settle: Spring
        var attachDuration: Double
        /// A thinking pill names what it is doing only when it takes this long.
        var captionDelay: Double
        var tooltipDelayMilliseconds: Int
        var pickerTooltipDelayMilliseconds: Int
        var hoverDuration: Double
        /// Content fades: the outgoing face leaves fast, the incoming one waits for the shape.
        var fadeOut: Double
        var fadeInDelay: Double
        var fadeIn: Double
        /// Hover lifts the body by this factor; a press sinks it.
        var hoverLift: CGFloat
        var pressSink: CGFloat
        /// Seconds per cycle of the glass's slow colour drift (0 = none).
        var drift: Double

        var attach: Animation { .easeOut(duration: attachDuration) }
        var hover: Animation { .easeOut(duration: hoverDuration) }

        /// The spring for one transition kind; nil with Reduce Motion.
        func spring(for kind: PillMotion, reduceMotion: Bool) -> Animation? {
            if reduceMotion { return nil }
            switch kind {
            case .instant: return quick.animation
            case .morph: return morph.animation
            case .settle: return settle.animation
            }
        }
    }

    var isGlass: Bool { if case .glass = renderer { return true }; return false }
}

// MARK: - The skins

extension PillSkin {
    private static let baseMetrics = Metrics(
        thickness: 30,
        resting: CGSize(width: 40, height: 8), restingCornerRadius: 4,
        readyLength: 50, readyOptions: 18, budSize: 28, budGap: 6, blend: 6,
        pushToTalkLength: 73, handsFreeLength: 102.5, thinkingLength: 80, errorLength: 73, meetingLength: 136,
        statusPadding: 12, statusGap: 8, polishLength: 168,
        controlDiameter: 18, controlGap: 6, pickerSize: 30, pickerGap: 2,
        noticePadding: 12, noticeMaxWidth: 300, noticeIcon: 13,
        cardPadding: 18, cardMinWidth: 300, cardMaxWidth: 400,
        tooltipPadding: 11, tooltipHeight: 26, micGlyph: 15)

    private static let baseMotion = Motion(
        quick: .init(response: 0.26, damping: 0.84), morph: .init(response: 0.38, damping: 0.78),
        settle: .init(response: 0.44, damping: 0.9),
        attachDuration: 0.18, captionDelay: 1.5,
        tooltipDelayMilliseconds: 600, pickerTooltipDelayMilliseconds: 600, hoverDuration: 0.12,
        fadeOut: 0.08, fadeInDelay: 0.10, fadeIn: 0.18, hoverLift: 1.0, pressSink: 0.98, drift: 0)

    private static let darkPalette = Palette(
        ink: Color(white: 0.96),
        inkSecondary: Color(white: 1, opacity: 0.58),
        inkFaint: Color(white: 1, opacity: 0.36),
        danger: Color(red: 1.0, green: 0.42, blue: 0.42),
        warning: Color(red: 0.98, green: 0.78, blue: 0.36),
        live: Color(red: 0.24, green: 0.80, blue: 0.60),
        controlFill: Color(white: 1, opacity: 0.16),
        controlInk: Color(white: 0.96),
        confirmFill: Color(white: 0.96),
        confirmInk: Color(white: 0.07),
        buttonFill: Color(white: 1, opacity: 0.10),
        buttonFillHover: Color(white: 1, opacity: 0.16),
        buttonInk: Color(white: 0.96),
        ringTrack: Color(white: 1, opacity: 0.10),
        ringProgress: Color(white: 1, opacity: 0.45),
        light: Color(white: 1, opacity: 0.16),
        dragDim: Color(white: 0.05, opacity: 0.55),
        dragZone: Color(white: 1, opacity: 0.10),
        dragZoneActive: Color(white: 1, opacity: 0.30))

    /// A dark plate with one thin edge. The default.
    static let standard = PillSkin(
        id: "default", name: "Default",
        palette: darkPalette,
        surface: Surface(
            corners: .capsule,  // fully rounded again (21 Nov 2026)
            fill: Color(white: 0.055, opacity: 0.94),
            restingFill: Color(white: 0.10, opacity: 0.92),
            restingEdge: Color(white: 1, opacity: 0.42),
            edge: Color(white: 1, opacity: 0.20),
            edgeHover: Color(white: 1, opacity: 0.26),
            edgeWidth: 0.75,
            shadow: Color.black.opacity(0.22),
            shadowRadius: 7, shadowY: 2,
            cardCornerRadius: 22),
        renderer: .plate,
        metrics: baseMetrics,
        type: TypeScale(family: .figtree, labelSize: 12, captionSize: 11, titleSize: 13, bodySize: 13, tooltipSize: 12),
        waveform: Waveform(barCount: 10, meetingBarCount: 5, barWidth: 2.2, barPitch: 4, restLength: 3, gain: 5,
                           roundEnds: true, wave: 1),
        motion: baseMotion)

    /// One approved glass family (21 Nov 2026 mockup). Thin, crisp glass: a lens bend at the rim, one sharp
    /// hairline of edge light, the rim lit by what is around it. Jet is the default.
    private static func glass(id: String, name: String, tint: Color, bevel: CGFloat, refraction: CGFloat,
                              dispersion: CGFloat, frost: CGFloat, magnify: CGFloat, dark: Bool,
                              shadow: Double, adaptiveInk: Bool = false) -> PillSkin {
        var skin = standard
        skin = PillSkin(id: id, name: name, palette: skin.palette, surface: skin.surface,
                        renderer: .glass(Glass(tint: tint, rim: Color(white: 1, opacity: 1),
                                               bevel: bevel, refraction: refraction, dispersion: dispersion, frost: frost,
                                               magnify: magnify, saturation: 0.0, dark: dark, adaptiveInk: adaptiveInk,
                                               fallbackTint: Color(white: 0.02, opacity: dark ? 0.82 : 0.4))),
                        metrics: skin.metrics, type: skin.type, waveform: skin.waveform, motion: skin.motion)
        skin.surface.shadow = Color.black.opacity(shadow)
        skin.surface.shadowRadius = 8
        skin.surface.shadowY = 3
        skin.surface.edgeWidth = 1
        skin.palette.light = Color(white: 1, opacity: 0)
        skin.motion.drift = 0
        skin.motion.hoverLift = 1.0
        skin.motion.hoverDuration = 0.12
        skin.motion.tooltipDelayMilliseconds = 600
        skin.motion.pickerTooltipDelayMilliseconds = 600
        return skin
    }

    /// C · Jet: near-black, razor edge light, no prism. The default.
    static let jet = glass(id: "jet", name: "Jet", tint: Color(white: 0, opacity: 0.94), bevel: 3.5, refraction: 5,
                           dispersion: 0, frost: 8, magnify: 0.02, dark: true, shadow: 0.45)
    /// D · Clear: see-through, crisp edge, small bend.
    static let clear = glass(id: "clear", name: "Clear", tint: Color(red: 0.08, green: 0.08, blue: 0.10, opacity: 0.35),
                             bevel: 4, refraction: 8, dispersion: 0.5, frost: 1.2, magnify: 0.05, dark: false, shadow: 0.25,
                             adaptiveInk: true)
    /// B · Liquid: lens bend, minimal prism, thin bright edge, a bit frosted.
    static let liquid = glass(id: "liquid", name: "Liquid", tint: Color(white: 1, opacity: 0.06), bevel: 6, refraction: 14,
                              dispersion: 0.9, frost: 2.8, magnify: 0.08, dark: false, shadow: 0.22,
                              adaptiveInk: true)

    /// Every skin, in the order settings list them (Jet first: the default).
    static let all: [PillSkin] = [.jet, .clear, .liquid, .standard]

    /// The skin a stored `pillSkin` value names. Unknown and retired values mean Default.
    static func named(_ id: String?) -> PillSkin {
        switch id {
        case "glassDark", "glass": return .jet       // retired names
        case "glassLight": return .liquid
        default: return all.first { $0.id == id } ?? .jet
        }
    }

    /// Light glass over a bright background: dark ink so the words stay readable.
    func adapted(toBackdropLuma luma: Double?) -> PillSkin {
        guard case .glass(let glass) = renderer, glass.adaptiveInk, let luma, luma > 0.6 else { return self }
        var skin = self
        skin.onBrightGlass = true
        skin.palette.ink = Color(white: 0.08)
        skin.palette.inkSecondary = Color(white: 0, opacity: 0.55)
        skin.palette.inkFaint = Color(white: 0, opacity: 0.32)
        skin.palette.controlFill = Color(white: 0, opacity: 0.10)
        skin.palette.controlInk = Color(white: 0.08)
        skin.palette.confirmFill = Color(white: 0.08)
        skin.palette.confirmInk = Color(white: 0.97)
        skin.palette.buttonFill = Color(white: 0, opacity: 0.08)
        skin.palette.buttonFillHover = Color(white: 0, opacity: 0.14)
        skin.palette.buttonInk = Color(white: 0.08)
        skin.palette.ringTrack = Color(white: 0, opacity: 0.10)
        skin.palette.ringProgress = Color(white: 0, opacity: 0.45)
        skin.palette.light = Color(white: 1, opacity: 0.5)
        return skin
    }
}

/// Glass skins flip to dark ink over a bright screen. With one threshold the pill changed style as the page behind it
/// scrolled, even mid-recording ("pill style is sometimes a bit inconsistent", 25 Nov 2026).
enum PillInk {
    static let turnsBright = 0.66
    static let turnsDark = 0.50

    /// Whether to use dark ink now. While the pill is in use (recording, working, a card) the choice holds still.
    static func bright(_ previous: Bool, luma: Double?, busy: Bool) -> Bool {
        guard !busy, let luma else { return previous }
        return previous ? luma > turnsDark : luma > turnsBright
    }
}

// MARK: - Environment

private struct PillSkinKey: EnvironmentKey {
    static let defaultValue = PillSkin.standard
}

/// Offscreen renders: no live screen capture and no system glass.
private struct PillOffscreenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var pillSkin: PillSkin {
        get { self[PillSkinKey.self] }
        set { self[PillSkinKey.self] = newValue }
    }
    var pillRendersOffscreen: Bool {
        get { self[PillOffscreenKey.self] }
        set { self[PillOffscreenKey.self] = newValue }
    }
}

// MARK: - Small plates (drag ghost, previews)

/// A small plate in the skin's look, for things outside the pill body (the drag ghost).
struct PillPlate: ViewModifier {
    @Environment(\.pillSkin) private var skin
    func body(content: Content) -> some View {
        content
            .background(PillShape().fill(skin.isGlass ? Color(white: 0.1, opacity: 0.6) : skin.surface.fill))
            .overlay(PillShape().strokeBorder(skin.surface.edge, lineWidth: skin.surface.edgeWidth))
            .shadow(color: skin.surface.shadow, radius: skin.surface.shadowRadius / 2, x: 0, y: skin.surface.shadowY / 2)
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    func pillPlate() -> some View { modifier(PillPlate()) }
}

/// The pill outline: a capsule, or a rounded rectangle whose radius never exceeds half the short
/// side. Insettable, so edges are drawn inside the plate; animatable, so corners spring.
struct PillShape: InsettableShape {
    var radius: CGFloat = .greatestFiniteMagnitude
    var inset: CGFloat = 0

    var animatableData: CGFloat {
        get { min(radius, 10_000) }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let limit = min(r.width, r.height) / 2
        if radius >= limit { return Capsule(style: .circular).path(in: r) }
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: r)
    }

    func inset(by amount: CGFloat) -> PillShape {
        var copy = self
        copy.inset += amount
        return copy
    }
}
