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
        activePipeline?.render(pixelBuffer: pixelBuffer)
    }
}

/// Interactive `CAMetalLayer`-backed `NSView` with flipped (top-left) coordinates for accurate phone touch/key/scroll injection.
public final class MirrorMetalNSView: NSView {
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    private let metalLayer = CAMetalLayer()
    public private(set) var renderPipeline: MetalRenderPipeline?
    public var videoSize: CGSize = .zero
    public var onControl: (@Sendable (Data) -> Void)?

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
        let factor: Float = event.hasPreciseScrollingDeltas ? 0.12 : 1.0
        let hScroll = Float(event.scrollingDeltaX) * factor
        let vScroll = Float(event.scrollingDeltaY) * factor
        guard hScroll != 0 || vScroll != 0 else { return }
        onControl?(ScrcpyControlEncoder.injectScroll(x: x, y: y, screenWidth: w, screenHeight: h, horizontalScroll: hScroll, verticalScroll: vScroll))
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
        let nx = max(0.0, min(1.0, local.x / bounds.width))
        let ny = max(0.0, min(1.0, local.y / bounds.height))
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
