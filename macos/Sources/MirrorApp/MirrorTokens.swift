import SwiftUI
import AppKit

/// Design tokens for the Graphite Studio + Teal aesthetic across dark and light macOS appearances.
public enum MirrorTokens {
    // 4px spacing ramp
    public static let space1: CGFloat = 4
    public static let space2: CGFloat = 8
    public static let space3: CGFloat = 12
    public static let space4: CGFloat = 16
    public static let space5: CGFloat = 20
    public static let space6: CGFloat = 24

    // Concentric radii
    public static let cardRadius: CGFloat = 14
    public static let innerRadius: CGFloat = 10
    public static let pillRadius: CGFloat = 8

    // Accent & semantic colors
    public static let accent = Color(red: 0.078, green: 0.722, blue: 0.651)       // #14B8A6
    public static let accentPressed = Color(red: 0.051, green: 0.580, blue: 0.533) // #0D9488
    public static let positive = Color(red: 0.133, green: 0.773, blue: 0.369)      // #22C55E
    public static let warning = Color(red: 0.961, green: 0.620, blue: 0.043)       // #F59E0B
    public static let danger = Color(red: 0.937, green: 0.267, blue: 0.267)        // #EF4444

    // Dynamic Graphite neutrals respecting Dark/Light mode
    public static let windowBg = Color(nsColor: .windowBackgroundColor)
    public static let stageBg = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.055, green: 0.063, blue: 0.075, alpha: 1) // #0E1013
            : NSColor(srgbRed: 0.941, green: 0.949, blue: 0.961, alpha: 1) // #F0F2F5
    })
    public static let cardSurface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.106, green: 0.118, blue: 0.137, alpha: 1) // #1B1E23
            : NSColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 1)
    })
    public static let raisedSurface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.145, green: 0.161, blue: 0.188, alpha: 1) // #252930
            : NSColor(srgbRed: 0.965, green: 0.973, blue: 0.980, alpha: 1)
    })
    public static let hairlineBorder = Color.primary.opacity(0.10)
    public static let chassisBody = Color(red: 0.098, green: 0.106, blue: 0.122)   // #191B1F
    public static let chassisRim = Color.white.opacity(0.16)
}
