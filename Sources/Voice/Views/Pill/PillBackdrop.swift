import AppKit
import CoreImage
import ScreenCaptureKit
import SwiftUI

// MARK: - What is behind the pill
//
// Glass skins refract a live capture of the screen under the pill's panel (the panel itself is
// excluded). The capture runs only while a glass skin is chosen and the pill is on screen: about
// 30 frames a second while the pill is open or working (`OverlayPanel.liveBackdropFps`). A resting pill runs no stream at all: it
// keeps the last frame, and takes one fresh frame only when it has none or the kept one is stale
// (see `PillBackdropPolicy`). Without Screen Recording permission nothing is captured and the glass
// falls back to a blur behind it; Flow never asks for the permission for this.

/// What the glass backdrop should do for the pill's current state. Pure so the idle rules can be tested.
enum PillBackdropPolicy {
    enum Mode: Equatable {
        /// Flat skin, hidden pill: no capture, no kept frame.
        case off
        /// Open or working pill: live stream at about 30 fps.
        case live
        /// Resting pill with a fresh enough frame: no stream, keep showing that frame.
        case hold
        /// Resting pill with no frame, or a stale one: capture one frame, then stop.
        case snapshot
    }

    /// A kept frame older than this is replaced the next time the pill rests.
    static let staleAfter: TimeInterval = 30

    static func mode(isGlass: Bool, isShown: Bool, resting: Bool, hasFrame: Bool, frameAge: TimeInterval) -> Mode {
        guard isGlass, isShown else { return .off }
        guard resting else { return .live }
        return hasFrame && frameAge <= staleAfter ? .hold : .snapshot
    }
}

/// One captured frame, covering the panel exactly, plus how bright it is.
struct PillBackdropFrame: Equatable {
    let image: CGImage
    /// Average brightness 0...1, for legible ink on light glass.
    let luma: Double
    /// Points per pixel column of `image` (2 on Retina).
    let scale: CGFloat

    static func == (a: PillBackdropFrame, b: PillBackdropFrame) -> Bool { a.image === b.image && a.luma == b.luma }
}

private struct PillBackdropKey: EnvironmentKey {
    static let defaultValue: PillBackdropFrame? = nil
}

extension EnvironmentValues {
    var pillBackdrop: PillBackdropFrame? {
        get { self[PillBackdropKey.self] }
        set { self[PillBackdropKey.self] = newValue }
    }
}

@MainActor
@Observable
final class PillBackdrop: NSObject {
    private(set) var frame: PillBackdropFrame?
    /// False when Screen Recording is not allowed: glass draws its fallback.
    private(set) var available = CGPreflightScreenCaptureAccess()

    /// Seconds since the kept frame was captured; infinite when there is none.
    var frameAge: TimeInterval { frame == nil ? .infinity : CACurrentMediaTime() - frameAt }

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: Output?
    @ObservationIgnored private var windowID: CGWindowID = 0
    @ObservationIgnored private var captured: CGRect = .zero
    @ObservationIgnored private var fps: Int = 0
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var frameAt: CFTimeInterval = 0
    @ObservationIgnored private var snapshotStartedAt: CFTimeInterval = 0
    /// What the latest request wants: a live stream, one snapshot frame, or nothing.
    @ObservationIgnored private var wanted: Wanted = .off

    private enum Wanted { case off, live, snapshot }

    /// Keeps the live capture in step with the panel: where it is, and how lively it should be.
    func follow(window: NSWindow, fps: Int) {
        available = CGPreflightScreenCaptureAccess()
        guard available, fps > 0, window.isVisible else { stop(); return }
        wanted = .live
        let rect = window.frame
        if stream == nil {
            guard !starting else { return }
            start(window: window, rect: rect, fps: fps)
            return
        }
        guard rect != captured || fps != self.fps else { return }
        captured = rect
        self.fps = fps
        guard let screen = window.screen else { return }
        let config = Self.configuration(rect: rect, screen: screen, fps: fps)
        stream?.updateConfiguration(config) { _ in }
    }

    /// Resting pill: stop the live stream but keep the last frame, so the glass keeps its backdrop.
    func hold() {
        wanted = .off
        halt()
    }

    /// Resting pill with no usable frame: capture one frame, then stop.
    func snapshot(window: NSWindow) {
        available = CGPreflightScreenCaptureAccess()
        guard available, window.isVisible else { stop(); return }
        wanted = .snapshot
        snapshotStartedAt = CACurrentMediaTime()
        if stream == nil, !starting { start(window: window, rect: window.frame, fps: 15) }
    }

    /// Turns the capture off and forgets the frame (skin is flat, or the pill is hidden).
    func stop() {
        wanted = .off
        halt()
        frame = nil
    }

    private func halt() {
        stream?.stopCapture { _ in }
        stream = nil
        output = nil
        fps = 0
    }

    /// A snapshot is done once a frame from this request has arrived.
    private func finishSnapshotIfDone() {
        guard wanted == .snapshot, frame != nil, frameAt >= snapshotStartedAt else { return }
        halt()
    }

    private func start(window: NSWindow, rect: CGRect, fps: Int) {
        starting = true
        windowID = CGWindowID(window.windowNumber)
        let id = windowID
        Task { @MainActor in
            defer { starting = false }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let screen = window.screen,
                  let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
            let mine = content.windows.filter { $0.windowID == id }
            let filter = SCContentFilter(display: display, excludingWindows: mine)
            let config = Self.configuration(rect: rect, screen: screen, fps: fps)
            let output = Output { [weak self] image, luma in
                Task { @MainActor in
                    guard let self else { return }
                    self.frame = PillBackdropFrame(image: image, luma: luma, scale: screen.backingScaleFactor)
                    self.frameAt = CACurrentMediaTime()
                    self.finishSnapshotIfDone()
                }
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            do {
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: Output.queue)
                try await stream.startCapture()
            } catch {
                PillDebugLog.write("backdrop capture failed: \(error.localizedDescription)")
                return
            }
            // Asked to stop while this was starting: shut it down instead of keeping it.
            guard self.wanted != .off else { stream.stopCapture { _ in }; return }
            self.stream = stream
            self.output = output
            self.captured = rect
            self.fps = fps
            self.finishSnapshotIfDone()
        }
    }

    /// Captures the panel's rectangle on its display at the display's pixel density.
    private static func configuration(rect: CGRect, screen: NSScreen, fps: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let display = screen.frame
        // Display-local, top-left origin.
        config.sourceRect = CGRect(x: rect.minX - display.minX, y: display.maxY - rect.maxY,
                                   width: rect.width, height: rect.height)
        config.width = Int(rect.width * screen.backingScaleFactor)
        config.height = Int(rect.height * screen.backingScaleFactor)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 3
        return config
    }

    /// Turns frames into images off the main thread; brightness is measured twice a second.
    private final class Output: NSObject, SCStreamOutput, @unchecked Sendable {
        static let queue = DispatchQueue(label: "flow.pill.backdrop", qos: .userInteractive)
        private let context = CIContext(options: [.cacheIntermediates: false])
        private let deliver: (CGImage, Double) -> Void
        private var luma = 0.5
        private var lastLuma: CFTimeInterval = 0

        init(deliver: @escaping (CGImage, Double) -> Void) { self.deliver = deliver }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, sampleBuffer.isValid, let buffer = sampleBuffer.imageBuffer else { return }
            let image = CIImage(cvPixelBuffer: buffer)
            guard let cg = context.createCGImage(image, from: image.extent) else { return }
            let now = CACurrentMediaTime()
            if now - lastLuma > 0.5 {
                lastLuma = now
                luma = Self.averageLuma(image, context: context)
            }
            deliver(cg, luma)
        }

        static func averageLuma(_ image: CIImage, context: CIContext) -> Double {
            guard let filter = CIFilter(name: "CIAreaAverage",
                                        parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: image.extent)]),
                  let output = filter.outputImage else { return 0.5 }
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
        }
    }
}

extension PillBackdropFrame {
    /// A still frame from a rendered view (offscreen inspection and previews).
    @MainActor static func still<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2) -> PillBackdropFrame? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        let ci = CIImage(cgImage: image)
        let luma = brightness(ci)
        return PillBackdropFrame(image: image, luma: luma, scale: scale)
    }

    private static func brightness(_ image: CIImage) -> Double {
        let context = CIContext()
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: image.extent)]),
              let output = filter.outputImage else { return 0.5 }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
    }
}
