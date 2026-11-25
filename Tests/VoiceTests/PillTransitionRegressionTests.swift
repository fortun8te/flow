import Testing
import CoreGraphics
@testable import Voice

/// The one body never slides: every look keeps its pinned point, stays inside the panel, and sends
/// its pieces toward the open side of the screen.
@Suite("Pill geometry on every dock", .serialized) @MainActor
struct PillTransitionRegressionTests {
    private let bounds = PillLayout.panelSize

    private func look(_ dock: PillDockEdge, _ change: (inout PillLookInput) -> Void) -> PillLook {
        var input = PillLookInput()
        input.dock = dock
        change(&input)
        return PillLookBuilder.look(input, skin: .standard)
    }

    private var looks: [(String, (inout PillLookInput) -> Void)] {
        let card = FlowPillNotice(kind: .microphone, message: "Microphone not responding.")
        let line = FlowPillNotice.wispr(forToast: "Select text first")
        return [
            ("resting", { _ in }),
            ("ready", { $0.hovered = true }),
            ("ready tip", { $0.hovered = true; $0.hoveredSegment = .dictate; $0.tipVisible = true }),
            ("listening", { $0.phase = .recording }),
            ("hands-free", { $0.phase = .locked }),
            ("hands-free tip", { $0.phase = .locked; $0.tipVisible = true }),
            ("thinking", { $0.phase = .transcribing }),
            ("polishing", { $0.phase = .polishingSelection }),
            ("pasted", { $0.phase = .undoPaste }),
            ("line", { $0.notice = line }),
            ("card", { $0.notice = card }),
            ("changes", { $0.phase = .polishDone; $0.changes = PolishDiff(original: "ok so", polished: "OK, so.") }),
            ("long changes", {
                $0.phase = .polishDone
                $0.changes = PolishDiff(original: String(repeating: "the quick brwn fox ", count: 60),
                                        polished: String(repeating: "the quick brown fox ", count: 60))
            }),
        ]
    }

    private func pinPoint(_ rect: CGRect, _ dock: PillDockEdge) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * dock.pin.x, y: rect.minY + rect.height * dock.pin.y)
    }

    @Test("Every look keeps the dock's pinned point, so nothing slides while the pill changes")
    func pinnedPointHolds() {
        for dock in PillDockEdge.allCases {
            let reference = pinPoint(PillLayoutEngine.geometry(look(dock) { _ in }, dock: dock, in: bounds, skin: .standard)
                .slot(.body).rect, dock)
            for (name, change) in looks {
                let body = PillLayoutEngine.geometry(look(dock, change), dock: dock, in: bounds, skin: .standard).slot(.body).rect
                let point = pinPoint(body, dock)
                #expect(abs(point.x - reference.x) < 0.5 && abs(point.y - reference.y) < 0.5, "\(dock) \(name): \(point) vs \(reference)")
            }
        }
    }

    @Test("Everything the pill shows stays inside its panel on every dock")
    func insidePanel() {
        let panel = CGRect(origin: .zero, size: bounds)
        for dock in PillDockEdge.allCases {
            for (name, change) in looks {
                let geometry = PillLayoutEngine.geometry(look(dock, change), dock: dock, in: bounds, skin: .standard)
                for slot in PillSlot.allCases where geometry.slot(slot).presence > 0 {
                    #expect(panel.contains(geometry.slot(slot).rect), "\(dock) \(name) \(slot): \(geometry.slot(slot).rect)")
                }
            }
        }
    }

    @Test("Pieces bud toward the open side: both ways at a centre dock, inward at a side or corner")
    func budsGoInward() {
        for dock in PillDockEdge.allCases {
            let geometry = PillLayoutEngine.geometry(look(dock) { $0.phase = .locked }, dock: dock, in: bounds, skin: .standard)
            let body = geometry.slot(.body).rect, lead = geometry.slot(.lead).rect, trail = geometry.slot(.trail).rect
            switch dock.inward {
            case 0: #expect(lead.maxX <= body.minX && trail.minX >= body.maxX, "\(dock)")
            case 1: #expect(lead.minX >= body.maxX && trail.minX >= lead.maxX, "\(dock)")
            default: #expect(lead.maxX <= body.minX && trail.maxX <= body.minX, "\(dock)")
            }
        }
    }

    @Test("Pieces that are not out sit merged inside the body, ready to bud")
    func mergedPieces() {
        let geometry = PillLayoutEngine.geometry(look(.bottom) { $0.phase = .recording }, dock: .bottom, in: bounds, skin: .standard)
        let body = geometry.slot(.body).rect
        for slot in [PillSlot.lead, .trail, .tip] {
            let frame = geometry.slot(slot)
            #expect(frame.presence == 0)
            #expect(body.insetBy(dx: -0.5, dy: -0.5).contains(frame.rect), "\(slot) \(frame.rect) in \(body)")
        }
        #expect(PillLayoutEngine.hitArea(geometry) == body)
    }

    @Test("Hands-free is one pill thick with its two buttons beside it")
    func handsFreeThickness() {
        for dock in PillDockEdge.allCases {
            let geometry = PillLayoutEngine.geometry(look(dock) { $0.phase = .locked }, dock: dock, in: bounds, skin: .standard)
            #expect(geometry.slot(.body).rect.height == PillSkin.standard.metrics.thickness)
            #expect(geometry.slot(.lead).presence == 1 && geometry.slot(.trail).presence == 1)
        }
    }

    @Test("The shape interpolates as one vector: halfway is halfway for every piece")
    func interpolation() {
        let a = PillLayoutEngine.geometry(look(.bottom) { _ in }, dock: .bottom, in: bounds, skin: .standard)
        let b = PillLayoutEngine.geometry(look(.bottom) { $0.phase = .locked }, dock: .bottom, in: bounds, skin: .standard)
        var delta = b - a
        delta.scale(by: 0.5)
        let mid = a + delta
        let body = mid.slot(.body).rect, ra = a.slot(.body).rect, rb = b.slot(.body).rect
        #expect(abs(body.width - (ra.width + rb.width) / 2) < 0.001)
        #expect(abs(mid.slot(.lead).presence - 0.5) < 0.001)
    }

    @Test("The panel sits at its dock inside the usable screen on every display")
    func panelPlacement() {
        let screens: [CGRect] = [CGRect(x: 0, y: 95, width: 1512, height: 850), CGRect(x: -2560, y: 0, width: 2560, height: 1415),
                                 CGRect(x: 1512, y: -300, width: 1920, height: 1055), CGRect(x: 0, y: 0, width: 320, height: 240)]
        let size = PillLayout.panelSize
        for visible in screens {
            for dock in PillDockEdge.allCases {
                let origin = PillLayout.panelOrigin(dock: dock, sideFraction: 0.5, visible: visible, bottomY: visible.minY + 30)
                let panel = CGRect(origin: origin, size: size)
                if visible.width >= size.width && visible.height >= size.height {
                    #expect(visible.contains(panel), "\(dock) \(visible) -> \(panel)")
                }
                #expect(origin.x.isFinite && origin.y.isFinite)
            }
            guard visible.width >= size.width else { continue }
            #expect(PillLayout.panelOrigin(dock: .left, sideFraction: 0.5, visible: visible, bottomY: visible.minY).x
                    == visible.minX + PillLayout.edgeGap)
            #expect(PillLayout.panelOrigin(dock: .right, sideFraction: 0.5, visible: visible, bottomY: visible.minY).x
                    == visible.maxX - size.width - PillLayout.edgeGap)
            #expect(PillLayout.panelOrigin(dock: .bottom, sideFraction: nil, visible: visible, bottomY: visible.minY + 30).y
                    == visible.minY + 30 + PillLayout.edgeGap)
        }
    }

    @Test("Every dock has a stored value that reads back, and drop zones pick the nearest dock")
    func docks() {
        for dock in PillDockEdge.allCases { #expect(PillDockEdge.from(anchor: dock.anchor) == dock) }
        #expect(PillDockEdge.from(anchor: "garbage") == .bottom)
        let area = CGSize(width: 1440, height: 900)
        for dock in PillDockEdge.allCases {
            #expect(PillDockEdge.nearest(to: dock.zoneCentre(in: area), in: area) == dock)
        }
        #expect(PillDockEdge.nearest(to: CGPoint(x: 5, y: 895), in: area) == .bottomLeft)
        #expect(PillDockEdge.nearest(to: CGPoint(x: 720, y: 3), in: area) == .top)
    }
}
