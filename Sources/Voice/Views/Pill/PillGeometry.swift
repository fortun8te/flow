import SwiftUI
import AppKit

// MARK: - Where the pill lives
//
// The pill docks at one of eight places. The panel is pinned to that place and the body is
// pinned inside the panel at the same point, so everything the pill becomes grows toward the
// open side of the screen: up from the bottom, down from the top, inward from a side or corner.

enum PillDockEdge: String, CaseIterable {
    case bottom, top, left, right, bottomLeft, bottomRight, topLeft, topRight

    /// The stored `voice.pillPosition` value.
    var anchor: String {
        switch self {
        case .bottom: return "bottomCenter"
        case .top: return "topCenter"
        default: return rawValue
        }
    }

    static func from(anchor: String) -> PillDockEdge {
        switch anchor {
        case "bottomCenter": return .bottom
        case "topCenter": return .top
        default: return PillDockEdge(rawValue: anchor) ?? .bottom
        }
    }

    /// The pinned point, as a fraction of the panel (and of the body).
    var pin: UnitPoint {
        switch self {
        case .bottom: return UnitPoint(x: 0.5, y: 1)
        case .top: return UnitPoint(x: 0.5, y: 0)
        case .left: return UnitPoint(x: 0, y: 0.5)
        case .right: return UnitPoint(x: 1, y: 0.5)
        case .bottomLeft: return UnitPoint(x: 0, y: 1)
        case .bottomRight: return UnitPoint(x: 1, y: 1)
        case .topLeft: return UnitPoint(x: 0, y: 0)
        case .topRight: return UnitPoint(x: 1, y: 0)
        }
    }

    var isSide: Bool { self == .left || self == .right }
    /// Horizontal direction toward the open screen: +1 right, -1 left, 0 both ways.
    var inward: CGFloat { pin.x == 0 ? 1 : pin.x == 1 ? -1 : 0 }
    /// Tips and lines sit on this side: -1 above, +1 below.
    var tipSide: CGFloat { pin.y == 0 ? 1 : -1 }

    /// The resting sliver lies along the edge it is docked on.
    func resting(_ size: CGSize) -> CGSize {
        isSide ? CGSize(width: size.height, height: size.width) : size
    }

    // MARK: Drop zones while moving the pill

    static let zoneLong: CGFloat = 112
    static let zoneShort: CGFloat = 70
    static let zoneInset: CGFloat = 10

    func zoneSize() -> CGSize {
        switch self {
        case .left, .right: return CGSize(width: Self.zoneShort, height: Self.zoneLong)
        case .bottom, .top: return CGSize(width: Self.zoneLong, height: Self.zoneShort)
        default: return CGSize(width: Self.zoneShort + 14, height: Self.zoneShort)
        }
    }

    /// Zone centre in a top-left space of `size` (the work area).
    func zoneCentre(in size: CGSize) -> CGPoint {
        let s = zoneSize()
        let x = pin.x * (size.width - 2 * Self.zoneInset - s.width) + Self.zoneInset + s.width / 2
        let y = pin.y * (size.height - 2 * Self.zoneInset - s.height) + Self.zoneInset + s.height / 2
        return CGPoint(x: x, y: y)
    }

    /// Where the dropped ghost lands: the pill's resting place.
    func anchor(in size: CGSize) -> CGPoint {
        CGPoint(x: pin.x * (size.width - 36) + 18, y: pin.y * (size.height - 36) + 18)
    }

    /// Nearest dock to a point by straight-line distance to the zone centres.
    static func nearest(to point: CGPoint, in size: CGSize) -> PillDockEdge {
        allCases.min { a, b in
            let pa = a.zoneCentre(in: size), pb = b.zoneCentre(in: size)
            return hypot(pa.x - point.x, pa.y - point.y) < hypot(pb.x - point.x, pb.y - point.y)
        } ?? .bottom
    }
}

// MARK: - The body's pieces

/// The body and the pieces that bud off it. Each is one rounded rectangle of the metaball field.
enum PillSlot: Int, CaseIterable {
    case body, tip, lead, trail
}

struct PillSlotFrame: Equatable {
    var rect: CGRect
    var radius: CGFloat
    /// 0 while merged into the body, 1 when fully out.
    var presence: CGFloat
}

/// Every slot's frame plus the blend radius, as one animatable vector, so the whole shape
/// springs as one.
struct PillGeometry: VectorArithmetic, Equatable {
    static let lanes = 6
    var values: SIMD32<Double>

    init(values: SIMD32<Double> = .zero) { self.values = values }

    init(slots: [PillSlotFrame], blend: CGFloat) {
        var v = SIMD32<Double>.zero
        for (i, s) in slots.prefix(PillSlot.allCases.count).enumerated() {
            let o = i * Self.lanes
            v[o] = s.rect.minX; v[o + 1] = s.rect.minY; v[o + 2] = s.rect.width; v[o + 3] = s.rect.height
            v[o + 4] = s.radius; v[o + 5] = s.presence
        }
        v[31] = blend
        values = v
    }

    func slot(_ slot: PillSlot) -> PillSlotFrame {
        let o = slot.rawValue * Self.lanes
        return PillSlotFrame(rect: CGRect(x: values[o], y: values[o + 1], width: max(0, values[o + 2]), height: max(0, values[o + 3])),
                             radius: max(0, values[o + 4]), presence: min(1, max(0, values[o + 5])))
    }

    var blend: CGFloat { max(0, values[31]) }

    /// The floats the shader reads: 6 per slot.
    var shaderValues: [Float] {
        (0..<(PillSlot.allCases.count * Self.lanes)).map { Float(values[$0]) }
    }

    static var zero: PillGeometry { PillGeometry() }
    static func + (a: PillGeometry, b: PillGeometry) -> PillGeometry { PillGeometry(values: a.values + b.values) }
    static func - (a: PillGeometry, b: PillGeometry) -> PillGeometry { PillGeometry(values: a.values - b.values) }
    mutating func scale(by rhs: Double) { values *= rhs }
    var magnitudeSquared: Double { (values * values).sum() }
}

// MARK: - Layout

enum PillLayoutEngine {
    /// Space between the body and the panel edge on its pinned side (room for the shadow).
    static let inset: CGFloat = 8

    /// The body's frame in a panel of `bounds`.
    static func bodyRect(_ size: CGSize, dock: PillDockEdge, in bounds: CGSize) -> CGRect {
        let pin = dock.pin
        let px = pin.x * (bounds.width - 2 * inset) + inset
        let py = pin.y * (bounds.height - 2 * inset) + inset
        return CGRect(x: px - size.width * pin.x, y: py - size.height * pin.y, width: size.width, height: size.height)
    }

    /// Every slot for a look, laid out from the body. Inactive pieces sit merged just inside the
    /// body edge they will bud from, so appearing and leaving both pass through a neck.
    static func geometry(_ look: PillLook, dock: PillDockEdge, in bounds: CGSize, skin: PillSkin,
                         lift: CGFloat = 1) -> PillGeometry {
        let m = skin.metrics
        var body = bodyRect(look.size, dock: dock, in: bounds)
        if lift != 1 { body = scaled(body, by: lift, pin: dock.pin) }
        let gap = m.budGap
        var slots = [PillSlotFrame](repeating: PillSlotFrame(rect: .zero, radius: 0, presence: 0), count: PillSlot.allCases.count)
        slots[PillSlot.body.rawValue] = PillSlotFrame(rect: body, radius: look.radius, presence: 1)

        // Side buds: both ways from a centred dock, inward from a side or corner.
        let budSizes = (lead: look.lead.map { $0.size(m) }, trail: look.trail.map { $0.size(m) })
        func budRect(_ size: CGSize, along offset: CGFloat, leading: Bool) -> CGRect {
            let y = body.midY - size.height / 2
            if dock.inward == 0 {
                return leading ? CGRect(x: body.minX - gap - size.width, y: y, width: size.width, height: size.height)
                               : CGRect(x: body.maxX + gap, y: y, width: size.width, height: size.height)
            }
            if dock.inward > 0 { return CGRect(x: body.maxX + gap + offset, y: y, width: size.width, height: size.height) }
            return CGRect(x: body.minX - gap - offset - size.width, y: y, width: size.width, height: size.height)
        }
        let leadSize = budSizes.lead ?? CGSize(width: m.thickness, height: m.thickness)
        let trailSize = budSizes.trail ?? CGSize(width: m.thickness, height: m.thickness)
        let leadRect: CGRect, trailRect: CGRect
        if dock.inward > 0 {
            leadRect = budRect(leadSize, along: 0, leading: false)
            trailRect = budRect(trailSize, along: (budSizes.lead == nil ? 0 : leadSize.width + gap), leading: false)
        } else if dock.inward < 0 {
            trailRect = budRect(trailSize, along: 0, leading: true)
            leadRect = budRect(leadSize, along: (budSizes.trail == nil ? 0 : trailSize.width + gap), leading: true)
        } else {
            leadRect = budRect(leadSize, along: 0, leading: true)
            trailRect = budRect(trailSize, along: 0, leading: false)
        }
        let corner: CGFloat
        switch skin.surface.corners {
        case .capsule: corner = .greatestFiniteMagnitude
        case .rounded(let r): corner = r
        }
        slots[PillSlot.lead.rawValue] = budFrame(active: budSizes.lead != nil, out: leadRect, body: body, m: m, corner: corner)
        slots[PillSlot.trail.rawValue] = budFrame(active: budSizes.trail != nil, out: trailRect, body: body, m: m, corner: corner)

        // The tip: above (or below, on a top dock), centred or aligned with the body's outer side.
        let tipSize = look.tip.map { CGSize(width: skin.type.width($0.label + ($0.key.isEmpty ? "" : " " + $0.key), .tooltip)
                                                + m.tooltipPadding * 2, height: m.tooltipHeight) }
            ?? CGSize(width: m.tooltipHeight * 2, height: m.tooltipHeight)
        let tipX: CGFloat
        switch dock.inward {
        case 0: tipX = body.midX - tipSize.width / 2
        case 1: tipX = body.minX
        default: tipX = body.maxX - tipSize.width
        }
        let tipY = dock.tipSide < 0 ? body.minY - gap - tipSize.height : body.maxY + gap
        let tipRect = CGRect(x: tipX, y: tipY, width: tipSize.width, height: tipSize.height)
        slots[PillSlot.tip.rawValue] = budFrame(active: look.tip != nil, out: tipRect, body: body, m: m, corner: corner)
        return PillGeometry(slots: slots, blend: look.blend ?? m.blend)
    }

    /// A bud fully out, or merged just inside the body edge it buds from.
    private static func budFrame(active: Bool, out: CGRect, body: CGRect, m: PillSkin.Metrics, corner: CGFloat) -> PillSlotFrame {
        let radius = min(corner, min(out.width, out.height) / 2)
        if active { return PillSlotFrame(rect: out, radius: radius, presence: 1) }
        let seed = min(body.height, out.height) * 0.5
        let cx = min(max(out.midX, body.minX + seed / 2), body.maxX - seed / 2)
        let cy = min(max(out.midY, body.minY + seed / 2), body.maxY - seed / 2)
        return PillSlotFrame(rect: CGRect(x: cx - seed / 2, y: cy - seed / 2, width: seed, height: seed),
                             radius: seed / 2, presence: 0)
    }

    private static func scaled(_ rect: CGRect, by factor: CGFloat, pin: UnitPoint) -> CGRect {
        let w = rect.width * factor, h = rect.height * factor
        let px = rect.minX + rect.width * pin.x, py = rect.minY + rect.height * pin.y
        return CGRect(x: px - w * pin.x, y: py - h * pin.y, width: w, height: h)
    }

    /// Union of the clickable pieces, for the panel's hit testing.
    static func hitArea(_ geometry: PillGeometry) -> CGRect {
        PillSlot.allCases.reduce(CGRect.null) { area, slot in
            let frame = geometry.slot(slot)
            return frame.presence > 0.5 && slot != .tip ? area.union(frame.rect) : area
        }
    }
}
