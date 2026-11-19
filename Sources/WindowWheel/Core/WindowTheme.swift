import SwiftUI
import AppKit

/// Native macOS AppKit vibrancy wrapper (hudWindow / popover) with continuous curvature
public struct NativeVibrancyBackground: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var cornerRadius: CGFloat
    public var tintOpacity: Double

    public init(
        material: NSVisualEffectView.Material = .hudWindow,
        cornerRadius: CGFloat = 20,
        tintOpacity: Double = 0.72
    ) {
        self.material = material
        self.cornerRadius = cornerRadius
        self.tintOpacity = tintOpacity
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.layer?.cornerRadius = cornerRadius
    }
}

/// Space Black & Brushed Titanium aesthetic shared across WeaponWheel, FileWheel, and WindowWheel
public enum WindowTheme {
    public static let obsidianDeep    = Color(red: 0.039, green: 0.043, blue: 0.051) // #0A0B0D
    public static let hudBackground   = Color(red: 0.055, green: 0.059, blue: 0.070) // #0E0F12
    public static let cardSurface     = Color(red: 0.088, green: 0.094, blue: 0.112) // #16181D
    public static let cardSelected    = Color(red: 0.130, green: 0.142, blue: 0.172) // #21242C
    public static let thumbWell       = Color(red: 0.032, green: 0.035, blue: 0.042)

    public static let platinumIce     = Color(red: 0.86, green: 0.90, blue: 0.96)   // #DCE6F5
    public static let steelSapphire   = Color(red: 0.49, green: 0.66, blue: 0.93)   // #7DA8ED
    public static let titaniumSilver  = Color(red: 0.56, green: 0.59, blue: 0.65)   // #8F96A6
    public static let champagneGold   = Color(red: 0.84, green: 0.73, blue: 0.56)   // #D6BA8F
    public static let anodizedSage    = Color(red: 0.46, green: 0.76, blue: 0.64)   // #75C2A3
    public static let smokedRose      = Color(red: 0.84, green: 0.54, blue: 0.60)   // #D68A99

    public static let labelPrimary    = Color(red: 0.96, green: 0.97, blue: 0.99)
    public static let labelSecondary  = Color(red: 0.56, green: 0.59, blue: 0.65)
    public static let labelMuted      = Color(red: 0.38, green: 0.41, blue: 0.47)
    public static let dividerStroke   = Color(white: 1.0, opacity: 0.08)
    public static let cardBorderSubtle = Color(white: 1.0, opacity: 0.08)

    public static var specularRimGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.24),
                Color.white.opacity(0.08),
                Color.white.opacity(0.03)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
