import AppKit
import SwiftUI

/// Moving the pill: past 5 pt of movement the screen dims, the eight places the pill can dock
/// show as soft zones and a small ghost follows the cursor. Releasing sends the ghost to the
/// nearest zone and the pill docks there. Escape cancels. Docks: `PillDockEdge` (PillGeometry.swift).
@MainActor
final class PillDragModel: ObservableObject {
    @Published var shown = false
    @Published var ghost = CGPoint.zero
    @Published var target: PillDockEdge = .bottom
    @Published var returning = false
}

private struct PillDragOverlayView: View {
    @ObservedObject var model: PillDragModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("pillSkin") private var storedSkin = "glass"
    private var skin: PillSkin { PillSkin.named(storedSkin) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                skin.palette.dragDim
                ForEach(PillDockEdge.allCases, id: \.self) { edge in
                    let size = edge.zoneSize()
                    let centre = edge.zoneCentre(in: proxy.size)
                    PillShape(radius: 22)
                        .fill(model.target == edge ? skin.palette.dragZoneActive : skin.palette.dragZone)
                        .overlay(PillShape(radius: 22)
                            .strokeBorder(Color.white.opacity(model.target == edge ? 0.5 : 0.18), lineWidth: 1))
                        .frame(width: size.width, height: size.height)
                        .scaleEffect(model.target == edge ? 1.08 : 1)
                        .position(centre)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.target)
                }
                ghost.position(model.ghost)
                    .animation(model.returning && !reduceMotion ? .timingCurve(0.2, 0.9, 0.3, 1, duration: 0.3) : nil,
                               value: model.ghost)
            }
        }
        .opacity(model.shown ? 1 : 0)
        .animation(model.shown ? .easeIn(duration: 0.12) : .easeOut(duration: 0.2), value: model.shown)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var ghost: some View {
        // Companion's own mark while dragging: the pointer from the app icon, not Wispr's logo.
        PurePointerGlyph().fill(skin.palette.ink)
            .frame(width: 14, height: 14)
            .frame(width: 30, height: 30)
            .pillPlate()
            .environment(\.pillSkin, skin)
    }
}

/// Runs one drag from the first 5 pt of movement to the drop. Blocks in an event-tracking
/// loop on the main thread, which is how AppKit tracks every mouse drag.
@MainActor
enum PillDragSession {
    static let threshold: CGFloat = 5
    private static let escapeKey: CGKeyCode = 53

    /// Returns the edge the pill was dropped on, or nil when cancelled with Escape.
    static func run(from sourceWindow: NSWindow) -> PillDockEdge? {
        let model = PillDragModel()
        var screen = screenUnderMouse() ?? sourceWindow.screen ?? NSScreen.main
        guard let firstScreen = screen else { return nil }

        let overlay = NSPanel(contentRect: firstScreen.visibleFrame, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.level = NSWindow.Level(rawValue: sourceWindow.level.rawValue + 1)
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        overlay.isReleasedWhenClosed = false
        overlay.contentView = NSHostingView(rootView: PillDragOverlayView(model: model))
        overlay.setFrame(firstScreen.visibleFrame, display: false)

        func place() {
            guard let screen else { return }
            let frame = screen.visibleFrame
            if overlay.frame != frame { overlay.setFrame(frame, display: true) }
            let mouse = NSEvent.mouseLocation
            // Top-left coordinates inside the overlay.
            let point = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
            model.ghost = point
            model.target = PillDockEdge.nearest(to: point, in: frame.size)
        }

        place()
        overlay.orderFrontRegardless()
        model.shown = true

        var cancelled = false
        tracking: while true {
            if CGEventSource.keyState(.combinedSessionState, key: escapeKey) { cancelled = true; break }
            guard let event = sourceWindow.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                                     until: Date().addingTimeInterval(0.05),
                                                     inMode: .eventTracking, dequeue: true) else {
                // No mouse event in this slice: still catch a released button the window never reported.
                if NSEvent.pressedMouseButtons & 1 == 0 { break }
                continue
            }
            switch event.type {
            case .leftMouseUp: break tracking
            default:
                if let under = screenUnderMouse(), under != screen { screen = under }
                place()
            }
        }

        let dropped: PillDockEdge? = cancelled ? nil : model.target
        if let dropped, let screen {
            model.returning = true
            model.ghost = dropped.anchor(in: screen.visibleFrame.size)
        }
        // Let the ghost land, then fade. The window outlives this call until the fade ends.
        DispatchQueue.main.asyncAfter(deadline: .now() + (dropped == nil ? 0 : 0.3)) {
            model.shown = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { overlay.orderOut(nil) }
        }
        return dropped
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }
}

/// Wispr's five-bar logo: rounded 2.02-wide bars, outer ones full height, the middle three shorter.
struct FlowLogoGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 15, sy = rect.height / 14
        let bars: [(x: CGFloat, top: CGFloat, bottom: CGFloat)] = [
            (0, 0, 14), (3.034, 6.41, 12.593), (6.073, 2.29, 11.612), (9.104, 6.41, 12.593), (12.138, 0, 14)
        ]
        var path = Path()
        for bar in bars {
            let r = CGRect(x: rect.minX + bar.x * sx, y: rect.minY + bar.top * sy,
                           width: 2.02 * sx, height: (bar.bottom - bar.top) * sy)
            path.addRoundedRect(in: r, cornerSize: CGSize(width: r.width / 2, height: r.width / 2), style: .circular)
        }
        return path
    }
}


/// The pointer from Companion's icon: a rounded dart with a small notch, drawn in a unit square.
struct PurePointerGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        let tip = point(0.04, 0.04), wing = point(0.98, 0.36), notch = point(0.56, 0.56), tail = point(0.36, 0.98)
        var path = Path()
        path.move(to: point(0.5, 0.2))
        path.addArc(tangent1End: wing, tangent2End: notch, radius: rect.width * 0.10)
        path.addArc(tangent1End: notch, tangent2End: tail, radius: rect.width * 0.02)
        path.addArc(tangent1End: tail, tangent2End: tip, radius: rect.width * 0.09)
        path.addArc(tangent1End: tip, tangent2End: wing, radius: rect.width * 0.09)
        path.closeSubpath()
        return path
    }
}
