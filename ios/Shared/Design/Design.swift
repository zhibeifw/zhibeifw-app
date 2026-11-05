import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 一个颜色令牌：浅色、深色两个值（ARGB），跟随系统深浅模式。
struct ZColor: Sendable, Hashable {
    let light: UInt32
    let dark: UInt32

    init(light: UInt32, dark: UInt32) { self.light = light; self.dark = dark }
    init(both: UInt32) { self.light = both; self.dark = both }

    #if os(macOS)
    var nsColor: NSColor {
        let l = light, d = dark
        return NSColor(name: nil) { a in
            a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(argb: d) : NSColor(argb: l)
        }
    }
    var color: Color { Color(nsColor: nsColor) }

    /// 打开“增强对比度”时换成 hc（HIG：支持增强对比度）。
    func color(highContrast hc: ZColor) -> Color {
        let n = nsColor, h = hc.nsColor
        return Color(nsColor: NSColor(name: nil) { _ in
            NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? h : n
        })
    }
    #else
    var uiColor: UIColor {
        let l = light, d = dark
        return UIColor { $0.userInterfaceStyle == .dark ? UIColor(argb: d) : UIColor(argb: l) }
    }
    var color: Color { Color(uiColor: uiColor) }

    /// 打开“增强对比度”时换成 hc（HIG：支持增强对比度）。
    func color(highContrast hc: ZColor) -> Color {
        let n = uiColor, h = hc.uiColor
        return Color(uiColor: UIColor { t in (t.accessibilityContrast == .high ? h : n).resolvedColor(with: t) })
    }
    #endif
}

#if os(macOS)
extension NSColor {
    convenience init(argb: UInt32) {
        self.init(
            srgbRed: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255,
            blue: CGFloat(argb & 0xFF) / 255, alpha: CGFloat((argb >> 24) & 0xFF) / 255)
    }
}
#else
extension UIColor {
    convenience init(argb: UInt32) {
        self.init(
            red: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255,
            blue: CGFloat(argb & 0xFF) / 255, alpha: CGFloat((argb >> 24) & 0xFF) / 255)
    }
}
#endif

/// 简写：界面代码里用 `C.labelPrimary`。
enum C {
    // 和系统语义色的值相同的直接用系统的（系统自带深色、增强对比度版本）
    #if os(tvOS)
    // tvOS 没有系统背景色（systemBackground 等），用令牌里的同值
    static var background: Color { Tok.Color.background.color }
    static var backgroundSecondary: Color { Tok.Color.backgroundSecondary.color }
    #elseif os(macOS)
    static var background: Color { Color(nsColor: .windowBackgroundColor) }
    static var backgroundSecondary: Color { Color(nsColor: .controlBackgroundColor) }
    #else
    static var background: Color { Color(uiColor: .systemBackground) }
    static var backgroundSecondary: Color { Color(uiColor: .secondarySystemBackground) }
    #endif
    #if os(macOS)
    static var labelPrimary: Color { Color(nsColor: .labelColor) }
    #else
    static var labelPrimary: Color { Color(uiColor: .label) }
    #endif
    // 比系统默认更深的几项：平时用我们的值，增强对比度时更深
    private static var hc: Tok.Color.HighContrast.Type { Tok.Color.HighContrast.self }
    static var labelSecondary: Color { Tok.Color.labelSecondary.color(highContrast: hc.labelSecondary) }
    static var labelTertiary: Color { Tok.Color.labelTertiary.color(highContrast: hc.labelTertiary) }
    static var separator: Color { Tok.Color.separator.color(highContrast: hc.separator) }
    static var danger: Color { Tok.Color.danger.color(highContrast: hc.danger) }
    static var onColor: Color { Tok.Color.onColor.color }
    static var iconDisabled: Color { Tok.Color.iconDisabled.color(highContrast: hc.iconDisabled) }
}

/// 字号令牌：字号、字重、行高。随系统字体大小缩放。
struct ZTextStyle: Sendable, Hashable {
    let size: CGFloat
    let weight: Int
    let lineHeight: CGFloat

    init(size: CGFloat, weight: Int, lineHeight: CGFloat) { self.size = size; self.weight = weight; self.lineHeight = lineHeight }

    var fontWeight: Font.Weight {
        switch weight {
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        default: return .bold
        }
    }
    #if !os(macOS)
    /// 这个字号对应的系统文字样式（HIG 字号阶梯），决定随系统字号放大的曲线。
    var textStyle: UIFont.TextStyle {
        switch size {
        #if os(tvOS)
        case 30...: return .title1  // tvOS 没有 largeTitle，最大是 title1
        #else
        case 30...: return .largeTitle  // 34
        #endif
        case 26..<30: return .title1  // 28
        case 21..<26: return .title2  // 22、24
        case 18..<21: return .title3  // 18、19、20
        case 16.5..<18: return .body  // 17
        case 15.5..<16.5: return .callout
        case 14..<15.5: return .subheadline  // 15
        case 12.5..<14: return .footnote  // 13
        case 11.5..<12.5: return .caption1  // 12
        default: return .caption2  // 11
        }
    }

    var uiWeight: UIFont.Weight {
        switch weight {
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        default: return .bold
        }
    }
    #endif
}

#if os(macOS)
/// Mac 没有系统字体大小（动态字体），固定为 1。
func fontScale(_ size: DynamicTypeSize) -> CGFloat { 1 }

private struct ZFontModifier: ViewModifier {
    let style: ZTextStyle
    let maxScale: CGFloat?

    func body(content: Content) -> some View {
        let natural = NSFont.systemFont(ofSize: style.size).boundingRectForFont.height
        return
            content
            .font(.system(size: style.size, weight: style.fontWeight))
            .lineSpacing(max(0, style.lineHeight - natural))
    }
}
#else
/// 系统字号缩放系数（相对于“默认”档）。和 Android 的 fontScale 对应。
func fontScale(_ size: DynamicTypeSize) -> CGFloat {
    let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
    return UIFontMetrics(forTextStyle: .body).scaledValue(for: 100, compatibleWith: traits) / 100
}

private struct ZFontModifier: ViewModifier {
    let style: ZTextStyle
    let maxScale: CGFloat?
    @Environment(\.dynamicTypeSize) private var dts

    func body(content: Content) -> some View {
        // 按 HIG：每个字号用对应的系统文字样式的放大曲线（大标题放大得少，小字放大得多），用 UIFontMetrics 换算
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dts))
        let metrics = UIFontMetrics(forTextStyle: style.textStyle)
        var s = metrics.scaledValue(for: style.size, compatibleWith: traits) / style.size
        if let m = maxScale { s = min(s, m) }
        let size = (style.size * s).rounded(.toNearestOrEven)
        let lineHeight = style.lineHeight * s
        let natural = UIFont.systemFont(ofSize: size, weight: style.uiWeight).lineHeight
        return
            content
            .font(.system(size: size, weight: style.fontWeight))
            .lineSpacing(max(0, lineHeight - natural))
            .padding(.vertical, max(0, lineHeight - natural) / 2)
    }
}
#endif

extension View {
    /// 用字号令牌设字体；maxScale 给固定尺寸的外壳（悬浮导航）封顶。
    func zFont(_ style: ZTextStyle, maxScale: CGFloat? = nil) -> some View {
        modifier(ZFontModifier(style: style, maxScale: maxScale))
    }
}

/// 1pt/1dp 取整到整数物理像素：3 倍屏 3 像素，2 倍屏 2 像素。
@MainActor func hairline(_ scale: CGFloat) -> CGFloat { max(1, (1 * scale).rounded()) / scale }

struct Separator: View {
    @Environment(\.displayScale) private var scale
    var body: some View { Rectangle().fill(C.separator).frame(height: hairline(scale)) }
}

extension Shape {
    /// iOS 用连续圆角。
    static func zRounded(_ r: CGFloat) -> RoundedRectangle { RoundedRectangle(cornerRadius: r, style: .continuous) }
}

/// 按下态：整块不透明度 0.7。
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? Tok.Motion.pressedOpacity : 1)
            .contentShape(Rectangle())
    }
}

extension View {
    func minTouch() -> some View { frame(minWidth: Tok.Space.MinTouchTarget.ios, minHeight: Tok.Space.MinTouchTarget.ios) }
}
