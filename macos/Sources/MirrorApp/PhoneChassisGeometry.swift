import Foundation
import CoreGraphics

/// Pure aspect-preserving geometry fitting a virtual phone chassis accurately around live video frames.
public struct PhoneChassisMetrics: Equatable, Sendable {
    public let screenSize: CGSize
    public let chassisSize: CGSize
    public let bezel: CGFloat
    public let innerCornerRadius: CGFloat
    public let outerCornerRadius: CGFloat
    public let cameraDiameter: CGFloat
    public let cameraTopOrSideInset: CGFloat
    public let isLandscape: Bool

    /// Computes exact screen dimensions inside `containerSize` matching `videoSize`'s aspect ratio
    /// and derives concentric outer bezel and camera cutout geometry around the fitted screen.
    public static func fit(videoSize: CGSize, in containerSize: CGSize, padding: CGFloat = 16) -> PhoneChassisMetrics {
        let validW = max(videoSize.width, 1)
        let validH = max(videoSize.height, 1)
        let aspect = validW / validH
        let isLandscape = validW > validH

        let roughMin = max(120, min(containerSize.width, containerSize.height) - padding * 2)
        let provisionalBezel = max(8, min(13, roughMin * 0.028))
        let sideButtonMargin: CGFloat = 3

        let maxScreenW = max(120, containerSize.width - padding * 2 - provisionalBezel * 2 - (isLandscape ? 0 : sideButtonMargin * 2))
        let maxScreenH = max(120, containerSize.height - padding * 2 - provisionalBezel * 2 - (isLandscape ? sideButtonMargin * 2 : 0))

        let screenSize: CGSize
        if (maxScreenW / maxScreenH) > aspect {
            let h = floor(maxScreenH)
            let w = floor(h * aspect)
            screenSize = CGSize(width: max(80, w), height: max(80, h))
        } else {
            let w = floor(maxScreenW)
            let h = floor(w / aspect)
            screenSize = CGSize(width: max(80, w), height: max(80, h))
        }

        let shortEdge = min(screenSize.width, screenSize.height)
        let bezel = max(8, min(12, round(shortEdge * 0.032)))
        let innerRadius = max(14, min(26, round(shortEdge * 0.075)))
        let outerRadius = innerRadius + bezel
        let cameraDiameter = max(9, min(13, round(shortEdge * 0.034)))
        let cameraInset = max(7, round(shortEdge * 0.025))

        return PhoneChassisMetrics(
            screenSize: screenSize,
            chassisSize: CGSize(width: screenSize.width + bezel * 2, height: screenSize.height + bezel * 2),
            bezel: bezel,
            innerCornerRadius: innerRadius,
            outerCornerRadius: outerRadius,
            cameraDiameter: cameraDiameter,
            cameraTopOrSideInset: cameraInset,
            isLandscape: isLandscape
        )
    }
}
