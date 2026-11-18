import Foundation
import SwiftUI
import AppKit
import QuartzCore
import CoreVideo

/// Thread-safe zero-copy frame sink forwarding decoded `CVPixelBuffer`s directly to `MetalRenderPipeline` without SwiftUI invalidation.
public final class MirrorFrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private var pipeline: MetalRenderPipeline?

    public init() {}

    public func attach(pipeline: MetalRenderPipeline?) {
        lock.lock()
        self.pipeline = pipeline
        lock.unlock()
    }

    public func submit(pixelBuffer: CVPixelBuffer) {
        lock.lock()
        let activePipeline = pipeline
        lock.unlock()
        _ = activePipeline?.render(pixelBuffer: pixelBuffer)
    }
}

/// Interactive `CAMetalLayer`-backed `NSView` with flipped (top-left) coordinates for accurate phone touch/key/scroll injection.
public final class MirrorMetalNSView: NSView {
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    private let metalLayer = CAMetalLayer()
    public private(set) var renderPipeline: MetalRenderPipeline?
    public var videoSize: CGSize = .zero {
        didSet {
            scroll.screen = videoSize
            pinch.screen = videoSize
        }
    }
    public var onControl: (@Sendable (Data) -> Void)?
    /// Files dropped on the view. When nil, the view refuses drops.
    public var onDropFiles: (([URL]) -> Void)?
    private var scroll = TrackpadScrollTranslator(screen: .zero)
    private var pinch = PinchTranslator(screen: .zero)

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    private func setupLayer() {
        wantsLayer = true
        metalLayer.contentsGravity = .resizeAspect
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.presentsWithTransaction = false
        layer = metalLayer
        renderPipeline = MetalRenderPipeline(metalLayer: metalLayer)
        registerForDraggedTypes([.fileURL])
    }

    // MARK: - File drop

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onDropFiles != nil && !droppedFiles(sender).isEmpty ? .copy : []
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = droppedFiles(sender)
        guard let onDropFiles, !urls.isEmpty else { return false }
        onDropFiles(urls)
        return true
    }

    private func droppedFiles(_ sender: any NSDraggingInfo) -> [URL] {
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL] ?? []).filter { !$0.hasDirectoryPath }
    }

    public override func layout() {
        super.layout()
        metalLayer.frame = bounds
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2.0
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        emitTouch(action: .down, event: event, pressure: 1.0, actionButton: ScrcpyControlEncoder.primaryButtonMask, buttons: ScrcpyControlEncoder.primaryButtonMask)
    }

    public override func mouseDragged(with event: NSEvent) {
        emitTouch(action: .move, event: event, pressure: 1.0, actionButton: 0, buttons: ScrcpyControlEncoder.primaryButtonMask)
    }

    public override func mouseUp(with event: NSEvent) {
        emitTouch(action: .up, event: event, pressure: 0.0, actionButton: ScrcpyControlEncoder.primaryButtonMask, buttons: 0)
    }

    public override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onControl?(ScrcpyControlEncoder.backOrScreenOnTap())
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let (x, y, w, h) = mappedPosition(from: event) else { return }
        let fit = videoRect
        // Points to phone pixels, so content moves under the fingers at the same speed.
        let scale = fit.width > 0 ? CGFloat(w) / fit.width : 1
        let outputs = scroll.handle(
            phase: Self.phase(of: event),
            location: CGPoint(x: CGFloat(x), y: CGFloat(y)),
            delta: CGVector(dx: event.scrollingDeltaX * scale, dy: event.scrollingDeltaY * scale),
            wheelDelta: CGVector(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
        )
        for output in outputs {
            switch output {
            case .touch(let action, let p):
                onControl?(ScrcpyControlEncoder.injectTouch(
                    action: action, pointerId: TrackpadScrollTranslator.fingerPointerId,
                    x: Int32(p.x.rounded()), y: Int32(p.y.rounded()), screenWidth: w, screenHeight: h,
                    pressure: action == .up ? 0 : 1, actionButton: 0, buttons: 0))
            case .wheel(let dx, let dy, let p):
                onControl?(ScrcpyControlEncoder.injectScroll(
                    x: Int32(p.x), y: Int32(p.y), screenWidth: w, screenHeight: h,
                    horizontalScroll: dx, verticalScroll: dy))
            }
        }
    }

    public override func magnify(with event: NSEvent) {
        guard let (x, y, w, h) = mappedPosition(from: event) else { return }
        let phase: PinchTranslator.Phase
        if event.phase.contains(.began) { phase = .began }
        else if event.phase.contains(.ended) || event.phase.contains(.cancelled) { phase = .ended }
        else { phase = .changed }
        let fingers = pinch.handle(phase: phase, location: CGPoint(x: CGFloat(x), y: CGFloat(y)),
                                   magnification: event.magnification)
        for finger in fingers {
            onControl?(ScrcpyControlEncoder.injectTouch(
                action: finger.action, pointerId: finger.pointerId,
                x: Int32(finger.point.x.rounded()), y: Int32(finger.point.y.rounded()),
                screenWidth: w, screenHeight: h,
                pressure: finger.action == .up ? 0 : 1, actionButton: 0, buttons: 0))
        }
    }

    static func phase(of event: NSEvent) -> TrackpadScrollTranslator.Phase {
        if !event.momentumPhase.isEmpty { return .momentum }
        let p = event.phase
        // mayBegin means fingers rest without moving; pressing then would read as a tap.
        if p.contains(.mayBegin) { return .momentum }
        if p.contains(.began) { return .began }
        if p.contains(.changed) { return .changed }
        if p.contains(.ended) { return .ended }
        if p.contains(.cancelled) { return .cancelled }
        return .none
    }

    /// Where the video sits inside the view (the layer letterboxes with `.resizeAspect`).
    var videoRect: CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    public override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "v" {
            if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                onControl?(ScrcpyControlEncoder.setClipboard(text, paste: true))
            }
            return
        }

        if !flags.contains(.command), !flags.contains(.control),
           let chars = event.characters, !chars.isEmpty,
           let scalar = chars.unicodeScalars.first,
           scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value) {
            onControl?(ScrcpyControlEncoder.injectText(chars))
            return
        }

        if let keycode = ScrcpyControlEncoder.androidKeyCode(macKeyCode: event.keyCode, charactersIgnoringModifiers: event.charactersIgnoringModifiers) {
            let meta = ScrcpyControlEncoder.androidMetaState(from: flags)
            onControl?(ScrcpyControlEncoder.injectKeycode(action: .down, keycode: keycode, repeatCount: event.isARepeat ? 1 : 0, metaState: meta))
        }
    }

    public override func keyUp(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !flags.contains(.command), !flags.contains(.control),
           let chars = event.characters, !chars.isEmpty,
           let scalar = chars.unicodeScalars.first,
           scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value) {
            return
        }
        if let keycode = ScrcpyControlEncoder.androidKeyCode(macKeyCode: event.keyCode, charactersIgnoringModifiers: event.charactersIgnoringModifiers) {
            let meta = ScrcpyControlEncoder.androidMetaState(from: flags)
            onControl?(ScrcpyControlEncoder.injectKeycode(action: .up, keycode: keycode, repeatCount: 0, metaState: meta))
        }
    }

    private func emitTouch(action: ScrcpyControlEncoder.TouchAction, event: NSEvent, pressure: Float, actionButton: UInt32, buttons: UInt32) {
        guard let (x, y, w, h) = mappedPosition(from: event) else { return }
        onControl?(ScrcpyControlEncoder.injectTouch(action: action, x: x, y: y, screenWidth: w, screenHeight: h, pressure: pressure, actionButton: actionButton, buttons: buttons))
    }

    private func mappedPosition(from event: NSEvent) -> (Int32, Int32, UInt16, UInt16)? {
        let wInt = Int(videoSize.width.rounded())
        let hInt = Int(videoSize.height.rounded())
        guard wInt > 0, hInt > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let fit = videoRect
        guard fit.width > 0, fit.height > 0 else { return nil }
        let nx = max(0.0, min(1.0, (local.x - fit.minX) / fit.width))
        let ny = max(0.0, min(1.0, (local.y - fit.minY) / fit.height))
        let w = UInt16(clamping: wInt)
        let h = UInt16(clamping: hInt)
        let px = Int32(clamping: Int((nx * CGFloat(w)).rounded()))
        let py = Int32(clamping: Int((ny * CGFloat(h)).rounded()))
        return (min(px, Int32(w) - 1), min(py, Int32(h) - 1), w, h)
    }
}

/// SwiftUI view embedding the zero-copy Metal mirroring surface inside the Mac window.
public struct MirrorSurfaceView: NSViewRepresentable {
    public let frameSink: MirrorFrameSink
    public let videoSize: CGSize
    public let onControl: @Sendable (Data) -> Void

    public init(frameSink: MirrorFrameSink, videoSize: CGSize, onControl: @escaping @Sendable (Data) -> Void) {
        self.frameSink = frameSink
        self.videoSize = videoSize
        self.onControl = onControl
    }

    public func makeNSView(context: Context) -> MirrorMetalNSView {
        let view = MirrorMetalNSView()
        view.videoSize = videoSize
        view.onControl = onControl
        frameSink.attach(pipeline: view.renderPipeline)
        return view
    }

    public func updateNSView(_ nsView: MirrorMetalNSView, context: Context) {
        nsView.videoSize = videoSize
        nsView.onControl = onControl
        frameSink.attach(pipeline: nsView.renderPipeline)
    }
}
