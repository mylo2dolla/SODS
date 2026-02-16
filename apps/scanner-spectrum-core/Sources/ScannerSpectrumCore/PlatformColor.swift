import SwiftUI

#if canImport(AppKit)
import AppKit
public typealias PlatformColor = NSColor
#elseif canImport(UIKit)
import UIKit
public typealias PlatformColor = UIColor
#endif

public enum PlatformColorSupport {
    public static func fromHSB(h: Double, s: Double, b: Double, a: Double = 1.0) -> PlatformColor {
        #if canImport(AppKit)
        return PlatformColor(calibratedHue: CGFloat(clamp(h)), saturation: CGFloat(clamp(s)), brightness: CGFloat(clamp(b)), alpha: CGFloat(clamp(a)))
        #else
        return PlatformColor(hue: CGFloat(clamp(h)), saturation: CGFloat(clamp(s)), brightness: CGFloat(clamp(b)), alpha: CGFloat(clamp(a)))
        #endif
    }

    public static func fromRGB(r: Double, g: Double, b: Double, a: Double = 1.0) -> PlatformColor {
        #if canImport(AppKit)
        return PlatformColor(calibratedRed: CGFloat(clamp(r)), green: CGFloat(clamp(g)), blue: CGFloat(clamp(b)), alpha: CGFloat(clamp(a)))
        #else
        return PlatformColor(red: CGFloat(clamp(r)), green: CGFloat(clamp(g)), blue: CGFloat(clamp(b)), alpha: CGFloat(clamp(a)))
        #endif
    }

    public static func hsba(_ color: PlatformColor) -> (h: Double, s: Double, b: Double, a: Double) {
        #if canImport(AppKit)
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 1
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b), Double(a))
        #else
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 1
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b), Double(a))
        #endif
    }

    public static func rgba(_ color: PlatformColor) -> (r: Double, g: Double, b: Double, a: Double) {
        #if canImport(AppKit)
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return (Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent), Double(rgb.alphaComponent))
        #else
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #endif
    }

    public static func mix(_ base: PlatformColor, _ accent: PlatformColor, ratio: Double) -> PlatformColor {
        let t = clamp(ratio)
        let b = rgba(base)
        let a = rgba(accent)
        return fromRGB(
            r: b.r * (1 - t) + a.r * t,
            g: b.g * (1 - t) + a.g * t,
            b: b.b * (1 - t) + a.b * t,
            a: b.a * (1 - t) + a.a * t
        )
    }

    public static func swiftUIColor(_ color: PlatformColor) -> Color {
        #if canImport(AppKit)
        return Color(nsColor: color)
        #else
        return Color(uiColor: color)
        #endif
    }
}

@inline(__always)
private func clamp(_ value: Double, min: Double = 0.0, max: Double = 1.0) -> Double {
    Swift.max(min, Swift.min(max, value))
}
