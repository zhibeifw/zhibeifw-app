import SwiftUI

/// 卡片与行的尺寸。W 是当前窗口宽度；≥ 600 用平板布局（按窗口宽度判断，不按设备类型）。
enum Layout {
    static func isTablet(_ w: CGFloat) -> Bool { w >= Tok.Space.tabletBreakpoint }
    static func pageMargin(_ w: CGFloat) -> CGFloat { isTablet(w) ? Tok.Space.pageMarginTablet : Tok.Space.pageMargin }

    /// 手机：大卡（新课程）1 张完整 + 右侧 36 露边，小卡一屏 1.5 张。
    /// 平板：一屏固定张数（竖屏、横屏各一套），卡宽随屏幕变，大屏上是大图少张，不是满屏小图。
    static func cardWidths(_ w: CGFloat, _ h: CGFloat) -> (large: CGFloat, small: CGFloat) {
        if isTablet(w) {
            let portrait = h >= w
            let n = portrait
                ? (Tok.Card.largePerScreenTabletPortrait, Tok.Card.smallPerScreenTabletPortrait)
                : (Tok.Card.largePerScreenTabletLandscape, Tok.Card.smallPerScreenTabletLandscape)
            let avail = w - pageMargin(w)
            return ((avail / n.0 - Tok.Space.cardGap).rounded(.down), (avail / n.1 - Tok.Space.cardGap).rounded(.down))
        }
        return (w - 68, ((w - 32) / 1.5).rounded(.down))
    }
    static func coverHeight(_ width: CGFloat) -> CGFloat { (width * 9 / 16).rounded() }
    static func seriesRowCoverWidth(_ w: CGFloat) -> CGFloat { (w * Tok.Component.SeriesRow.coverRatio).rounded() }
    static func tileColumns(_ w: CGFloat) -> Int { isTablet(w) ? Int(Tok.Card.TileColumns.tablet) : Int(Tok.Card.TileColumns.phone) }
    static func isLargeText(_ scale: CGFloat) -> Bool { scale >= Tok.Font.largeTextScale }

    /// 页面内容底部给悬浮导航留的空白：展开时两层的总高度 + 8 + 16（安全区由系统另加）。
    static var navReserve: CGFloat { Tok.Space.scale[3] }  // 标签栏、播放胶囊由系统留出安全区，这里只留一点底部空白
}

/// 当前窗口宽度、高度（页面用它算卡宽、边距；高度只用来分平板的竖屏、横屏）。
private struct WindowWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 390 }
private struct WindowHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 844 }
extension EnvironmentValues {
    var windowWidth: CGFloat {
        get { self[WindowWidthKey.self] }
        set { self[WindowWidthKey.self] = newValue }
    }
    var windowHeight: CGFloat {
        get { self[WindowHeightKey.self] }
        set { self[WindowHeightKey.self] = newValue }
    }
}
