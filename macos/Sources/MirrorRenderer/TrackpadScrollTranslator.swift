import CoreGraphics

/// Turns Mac scroll input into phone input.
///
/// Android flings a list only after a touch drag; wheel events scroll a fixed step and stop.
/// So a two-finger trackpad scroll becomes a one-finger drag that starts under the cursor and
/// follows the scroll deltas. When the fingers lift, Android sees the drag end at speed and
/// flings. macOS momentum events are dropped, since Android runs its own fling.
///
/// A mouse wheel has no scroll phases and still sends wheel events.
public struct TrackpadScrollTranslator: Sendable {
    public enum Phase: Sendable, Equatable {
        case began, changed, ended, cancelled
        /// No phase: a mouse wheel notch.
        case none
        /// macOS momentum after the fingers lift.
        case momentum
    }

    public enum Output: Equatable, Sendable {
        case touch(ScrcpyControlEncoder.TouchAction, CGPoint)
        case wheel(dx: Float, dy: Float, at: CGPoint)
    }

    /// scrcpy's id for a finger that is not the mouse (`POINTER_ID_GENERIC_FINGER`). Keeps the
    /// scroll drag separate from a mouse click in progress.
    public static let fingerPointerId = UInt64(bitPattern: -2)

    /// Phone pixels kept clear of each edge. A drag that reaches this margin lifts and starts
    /// again at its first point, so long scrolls never stall at the screen edge.
    public static let edgeMargin: CGFloat = 8

    /// Phone screen size in pixels.
    public var screen: CGSize
    private var start: CGPoint?
    private var current: CGPoint = .zero

    public init(screen: CGSize) {
        self.screen = screen
    }

    public var isDragging: Bool { start != nil }

    /// - Parameters:
    ///   - location: cursor position in phone pixels.
    ///   - delta: `scrollingDeltaX/Y` already converted to phone pixels.
    ///   - wheelDelta: the raw deltas, used only for mouse wheel events.
    public mutating func handle(phase: Phase, location: CGPoint, delta: CGVector, wheelDelta: CGVector) -> [Output] {
        switch phase {
        case .momentum:
            return []
        case .none:
            guard wheelDelta.dx != 0 || wheelDelta.dy != 0 else { return [] }
            return [.wheel(dx: Float(wheelDelta.dx), dy: Float(wheelDelta.dy), at: clamp(location))]
        case .began:
            var out = finish()
            let point = clamp(location)
            start = point
            current = point
            out.append(.touch(.down, point))
            return out
        case .changed:
            guard let origin = start else {
                // Missed the began event (cursor entered mid-gesture); start here.
                return handle(phase: .began, location: location, delta: .zero, wheelDelta: .zero)
            }
            let next = CGPoint(x: current.x + delta.dx, y: current.y + delta.dy)
            if next == current { return [] }
            if inside(next) {
                current = next
                return [.touch(.move, next)]
            }
            // Edge reached: lift, then press again at the first point and keep going.
            let lifted = clamp(next)
            current = origin
            return [.touch(.move, lifted), .touch(.up, lifted), .touch(.down, origin)]
        case .ended, .cancelled:
            return finish()
        }
    }

    private mutating func finish() -> [Output] {
        guard start != nil else { return [] }
        start = nil
        return [.touch(.up, current)]
    }

    private func inside(_ p: CGPoint) -> Bool {
        let m = Self.edgeMargin
        return p.x >= m && p.y >= m && p.x <= screen.width - m && p.y <= screen.height - m
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        let m = Self.edgeMargin
        return CGPoint(x: min(max(p.x, m), max(m, screen.width - m)),
                       y: min(max(p.y, m), max(m, screen.height - m)))
    }
}
