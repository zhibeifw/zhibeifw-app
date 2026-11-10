import SwiftUI

/// watchOS 界面使用系统文字样式；共用调色板仍使用相同的颜色值。
struct ZColor: Sendable, Hashable {
    let light: UInt32
    let dark: UInt32
    init(light: UInt32, dark: UInt32) { self.light = light; self.dark = dark }
    init(both: UInt32) { light = both; dark = both }
    var color: Color {
        Color(
            .sRGB, red: Double((dark >> 16) & 255) / 255,
            green: Double((dark >> 8) & 255) / 255, blue: Double(dark & 255) / 255,
            opacity: Double((dark >> 24) & 255) / 255)
    }
}

struct ZTextStyle: Sendable, Hashable {
    let size: CGFloat
    let weight: Int
    let lineHeight: CGFloat
}

enum C {
    static var labelPrimary: Color { .primary }
    static var backgroundSecondary: Color { Tok.Color.backgroundSecondary.color }
}
