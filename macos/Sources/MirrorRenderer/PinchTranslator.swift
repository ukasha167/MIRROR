import CoreGraphics

/// Turns a trackpad pinch into two phone fingers that move apart or together around the cursor.
///
/// macOS reports a pinch as a running magnification (`NSEvent.magnification`, about +0.01 per
/// event). Android has no zoom event, so maps and photos zoom only from two touching fingers.
public struct PinchTranslator: Sendable {
    public enum Phase: Sendable, Equatable { case began, changed, ended }

    public struct Finger: Equatable, Sendable {
        public var pointerId: UInt64
        public var action: ScrcpyControlEncoder.TouchAction
        public var point: CGPoint
    }

    /// Two ids no other input uses (the mouse is -1, the scroll finger -2).
    public static let pointerIds: (UInt64, UInt64) = (100, 101)
    /// Distance between the fingers when the pinch starts, in phone pixels.
    public static let startSpan: CGFloat = 300
    /// Fingers stay at least this far apart, so they never land on one point.
    public static let minSpan: CGFloat = 40

    public var screen: CGSize
    private var center: CGPoint?
    private var span = PinchTranslator.startSpan

    public init(screen: CGSize) { self.screen = screen }

    /// `location` is the cursor in phone pixels; it is read only when the pinch begins.
    public mutating func handle(phase: Phase, location: CGPoint, magnification: CGFloat) -> [Finger] {
        switch phase {
        case .began:
            center = location
            span = Self.startSpan
            span = clampedSpan(span * (1 + magnification))
            return fingers(.down)
        case .changed:
            guard center != nil else { return [] }
            span = clampedSpan(span * (1 + magnification))
            return fingers(.move)
        case .ended:
            guard center != nil else { return [] }
            defer { center = nil }
            return fingers(.up)
        }
    }

    /// Both fingers must stay on the screen, or Android drops the gesture.
    private func clampedSpan(_ value: CGFloat) -> CGFloat {
        guard let center else { return value }
        let room = 2 * min(center.x, screen.width - 1 - center.x)
        return max(Self.minSpan, min(value, max(room, Self.minSpan)))
    }

    private func fingers(_ action: ScrcpyControlEncoder.TouchAction) -> [Finger] {
        guard let center else { return [] }
        let half = span / 2
        return [
            Finger(pointerId: Self.pointerIds.0, action: action, point: CGPoint(x: center.x - half, y: center.y)),
            Finger(pointerId: Self.pointerIds.1, action: action, point: CGPoint(x: center.x + half, y: center.y)),
        ]
    }
}
