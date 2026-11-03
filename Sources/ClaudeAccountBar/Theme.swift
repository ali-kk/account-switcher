import AppKit
import SwiftUI

/// Claude's palette: clay orange on warm cream (light) or warm charcoal (dark).
enum Theme {
    static let clay = Color(light: 0xD97757, dark: 0xD97757)
    static let clayDeep = Color(light: 0xC15F3C, dark: 0xE08A6C)
    static let claySoft = Color(light: 0xF6E3DA, dark: 0x4A3129)
    static let background = Color(light: 0xFAF9F5, dark: 0x262624)
    static let card = Color(light: 0xF0EEE6, dark: 0x30302E)
    static let cardHover = Color(light: 0xE8E6DC, dark: 0x393936)
    static let border = Color(light: 0xE3E1D7, dark: 0x41403C)
    static let text = Color(light: 0x141413, dark: 0xF5F4EE)
    static let secondary = Color(light: 0x6B6A64, dark: 0xA3A29B)
    static let track = Color(light: 0xE3E1D7, dark: 0x45443F)
    static let good = Color(light: 0x5B8C5A, dark: 0x8DBF8B)
    static let warn = Color(light: 0xD4A027, dark: 0xE6B84A)
    static let danger = Color(light: 0xC8473D, dark: 0xE5675C)

    static func usageColor(_ pct: Double) -> Color {
        pct >= 100 ? danger : pct >= 80 ? warn : clay
    }

    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.82)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Animation that turns itself off under Reduce Motion.
struct MotionAware: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: AnyHashable

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    func motion<V: Hashable>(_ animation: Animation = Theme.spring, value: V) -> some View {
        modifier(MotionAware(animation: animation, value: AnyHashable(value)))
    }
}
