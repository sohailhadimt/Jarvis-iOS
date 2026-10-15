import SwiftUI
import UIKit

enum Theme {
    static let defaultPrimaryHex = "00D8FFFF"   // cyan-blue glow
    static let defaultAccentHex = "D4AF37FF"    // gold
    static var background: LinearGradient {
        LinearGradient(
        colors: [Color(red: 0.02, green: 0.04, blue: 0.12), .black],
        startPoint: .top, endPoint: .bottom)
    }
}

extension Color {
    /// Accepts RRGGBB or RRGGBBAA (optionally prefixed with #).
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 6 { s += "FF" }
        var value: UInt64 = 0
        guard s.count == 8, Scanner(string: s).scanHexInt64(&value) else {
            self = .cyan
            return
        }
        let r = Double((value >> 24) & 0xFF) / 255
        let g = Double((value >> 16) & 0xFF) / 255
        let b = Double((value >> 8) & 0xFF) / 255
        let a = Double(value & 0xFF) / 255
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X%02X", c(r), c(g), c(b), c(a))
    }
}
