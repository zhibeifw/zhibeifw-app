import SwiftUI

/// 卡片与行的尺寸。W 是当前窗口宽度；≥ 600 用平板布局（按窗口宽度判断，不按设备类型）。
enum Layout {
    static func isTablet(_ w: CGFloat) -> Bool { w >= Tok.Space.tabletBreakpoint }
    static func pageMargin(_ w: CGFloat) -> CGFloat { isTablet(w) ? Tok.Space.pageMarginTablet : Tok.Space.pageMargin }

    /// 大卡（新课程）：1 张完整 + 右侧 36 露边；小卡：一屏 1.5 张。
    static func cardWidths(_ w: CGFloat) -> (large: CGFloat, small: CGFloat) {
        if isTablet(w) { return (Tok.Card.largeWidthTablet, Tok.Card.smallWidthTablet) }
        return (w - 68, ((w - 32) / 1.5).rounded(.down))
    }
    static func coverHeight(_ width: CGFloat) -> CGFloat { (width * 9 / 16).rounded() }
    static func seriesRowCoverWidth(_ w: CGFloat) -> CGFloat { (w * Tok.Component.SeriesRow.coverRatio).rounded() }
    static func tileColumns(_ w: CGFloat) -> Int { isTablet(w) ? Int(Tok.Card.TileColumns.tablet) : Int(Tok.Card.TileColumns.phone) }
    static func isLargeText(_ scale: CGFloat) -> Bool { scale >= Tok.Font.largeTextScale }

    /// 页面内容底部给悬浮导航留的空白：展开时两层的总高度 + 8 + 16（安全区由系统另加）。
    static var navReserve: CGFloat { Tok.Space.scale[3] }  // 标签栏、播放胶囊由系统留出安全区，这里只留一点底部空白
}

/// 当前窗口宽度（页面用它算卡宽、边距）。
private struct WindowWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 390 }
extension EnvironmentValues {
    var windowWidth: CGFloat {
        get { self[WindowWidthKey.self] }
        set { self[WindowWidthKey.self] = newValue }
    }
}
