import SwiftUI

typealias S = Tok.Font.Style
typealias CP = Tok.Component

// MARK: - 页面骨架：自绘页头

/// 二级页面（以及主页、搜索页）的骨架：可滚动内容 + 顶部自绘页头。
/// 大标题放在内容最上面随内容滚走；滚走后页头中间淡入 17/600 小标题并出现分隔线。
struct PageScaffold<Content: View, Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    var showBack = true
    var largeTitle = true
    var centeredTitle = false
    /// 没有大标题的页面（系列页）：滚过这么多后页头才淡入小标题。
    var revealAt: CGFloat? = nil
    var onRefresh: (() async -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.windowWidth) private var W
    @State private var offset: CGFloat = 0

    var body: some View {
        let m = Layout.pageMargin(W)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 副标题（如资料库“2 门课 · 12 节”）放在系统大标题下面
                // 卡片副标题（新课程的“更新至 第 N 课”）：所有系统版本都显示
                if let subtitle {
                    Text(subtitle).zFont(S.caption).foregroundStyle(C.labelSecondary)
                        .padding(.horizontal, m).padding(.bottom, CP.PageTitle.bottomGap)
                }
                content()
                Color.clear.frame(height: Layout.navReserve)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self) {
            $0.contentOffset.y + $0.contentInsets.top
        } action: { _, y in
            offset = y
            model.feedScroll(Double(y))
        }
        .refreshable(enabled: onRefresh != nil) { await onRefresh?() }
        .background(C.background)
        // 页头用系统导航栏：系统大标题（滚动时自动收成小标题）、系统返回键、右边按钮放系统工具栏
        .navigationTitle(navTitle)
        .systemSubtitle(subtitle)
        // 一级页（主页、搜索，没有返回键）大标题；子页（有返回键）一律小标题，不管有没有副标题、列表是不是空的
        .navigationBarTitleDisplayMode(largeTitle && !showBack ? .large : .inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { trailing() } }
    }

    /// 系列页没有大标题：封面和课程名滚出去之后，系统小标题才显示课程名。
    private var navTitle: String {
        if let r = revealAt { return offset > r ? title : "" }
        return title
    }
}

private var hasSystemSubtitle: Bool {
    if #available(iOS 26.0, *) { return true } else { return false }
}

extension View {
    /// 导航栏副标题（如资料库“2 门课 · 12 节”）：iOS 26 起用系统的 navigationSubtitle（HIG）。
    @ViewBuilder func systemSubtitle(_ text: String?) -> some View {
        if #available(iOS 26.0, *), let text { self.navigationSubtitle(text) } else { self }
    }
}

extension PageScaffold where Trailing == EmptyView {
    init(
        title: String, subtitle: String? = nil, showBack: Bool = true, largeTitle: Bool = true, centeredTitle: Bool = false,
        onRefresh: (() async -> Void)? = nil, @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title, subtitle: subtitle, showBack: showBack, largeTitle: largeTitle, centeredTitle: centeredTitle,
            onRefresh: onRefresh, trailing: { EmptyView() }, content: content)
    }
}

extension View {
    @ViewBuilder func refreshable(enabled: Bool, action: @escaping @Sendable () async -> Void) -> some View {
        if enabled { refreshable(action: action) } else { self }
    }
}

// MARK: - 板块标题

struct SectionTitle: View {
    var title: String
    var action: (() -> Void)? = nil
    @Environment(\.windowWidth) private var W
    var body: some View {
        Group {
            if let action {
                Button(action: action) { label(arrow: true) }.buttonStyle(PressableStyle())
                    .accessibilityLabel("\(title)，点按查看全部课程")
            } else {
                label(arrow: false).accessibilityAddTraits(.isHeader)
            }
        }
        .padding(.horizontal, Layout.pageMargin(W))
    }
    private func label(arrow: Bool) -> some View {
        HStack(spacing: CP.SectionTitle.arrowGap) {
            Text(title).zFont(S.sectionTitle).foregroundStyle(C.labelPrimary)
            if arrow { ZIcon(name: "chevron-forward", size: CP.SectionTitle.arrowSize, color: C.labelTertiary) }
            Spacer(minLength: 0)
        }
        // 触控区补足到 44，但不撑大排版（标题与卡片行的间距保持 8）
        .contentShape(Rectangle().inset(by: -(CP.SectionTitle.minTouch - S.sectionTitle.lineHeight) / 2))
    }
}

// MARK: - 内容卡片与横滑行

struct ContentCard: View {
    var card: SeriesCard
    var width: CGFloat
    var large: Bool
    var title: String
    var subtitle: String? = nil
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                CoverImage(path: card.coverPath, colorId: card.id, radius: large ? Tok.Radius.cardLarge : Tok.Radius.cardSmall)
                    .frame(width: width, height: Layout.coverHeight(width))
                Text(title).zFont(S.cardTitle).foregroundStyle(C.labelPrimary).lineLimit(2).multilineTextAlignment(.leading)
                    .padding(.top, Tok.Space.cardImageToTitle)
                // 卡片副标题（新课程的“更新至 第 N 课”）：所有系统版本都显示
                if let subtitle {
                    Text(subtitle).zFont(S.caption).foregroundStyle(C.labelSecondary).lineLimit(1).padding(.top, 2)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)\(subtitle.map { "，\($0)" } ?? "")，点按进入系列详情")
        .accessibilityAddTraits(.isButton)
    }
}

/// 横向卡片行：首卡对齐页边距，卡间距 12，按卡片吸附滚动，不显示滚动条。
struct CardRow: View {
    var cards: [SeriesCard]
    var large: Bool
    var titleOf: (SeriesCard) -> String = { $0.title }
    var subtitleOf: (SeriesCard) -> String? = { _ in nil }
    var onTap: (SeriesCard) -> Void
    @Environment(\.windowWidth) private var W
    @Environment(\.dynamicTypeSize) private var dts

    var body: some View {
        let widths = Layout.cardWidths(W)
        let largeText = Layout.isLargeText(fontScale(dts))
        let w = large || largeText ? widths.large : widths.small
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: Tok.Space.cardGap) {
                ForEach(cards) { c in
                    ContentCard(card: c, width: w, large: large, title: titleOf(c), subtitle: subtitleOf(c)) { onTap(c) }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, Layout.pageMargin(W))
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
    }
}

// MARK: - 大图列表行 H2（分类完整列表、收藏夹、资料库第一层）

struct SeriesRowView: View {
    var id: String
    var title: String
    var meta: [String]
    var coverPath: String
    var localCover: URL? = nil
    /// 有菜单时（收藏夹、资料库）右边是“•••”（去掉滑动后，操作都放这里），没有就是箭头
    var menu: (() -> [[MenuItem]])? = nil
    var action: () -> Void
    @Environment(\.windowWidth) private var W
    @Environment(\.dynamicTypeSize) private var dts

    var body: some View {
        let m = Layout.pageMargin(W)
        let large = Layout.isLargeText(fontScale(dts))
        row(m: m, large: large)
            // “•••”放在行按钮外面，点它不会进入课程
            .overlay(alignment: large ? .bottomTrailing : .trailing) {
                if let menu { MoreButton(items: menu).padding(.trailing, m - (CP.EpisodeRow.moreTouch - CP.EpisodeRow.moreIcon) / 2) }
            }
    }

    private func row(m: CGFloat, large: Bool) -> some View {
        let cw = Layout.seriesRowCoverWidth(min(W, Tok.Card.seriesRowMaxWidth))
        return Button(action: action) {
            Group {
                if large {
                    VStack(alignment: .leading, spacing: CP.SeriesRow.textGap) {
                        CoverImage(path: coverPath, colorId: id, radius: Tok.Radius.cardSmall, localFile: localCover)
                            .frame(height: Layout.coverHeight(W - 2 * m))
                        texts(lines: nil)
                    }
                } else {
                    HStack(spacing: CP.SeriesRow.textGap) {
                        CoverImage(path: coverPath, colorId: id, radius: Tok.Radius.cardSmall, localFile: localCover)
                            .frame(width: cw, height: Layout.coverHeight(cw))
                        texts(lines: 2)
                        Spacer(minLength: 0)
                        if menu == nil {
                            ZIcon(name: "chevron-forward", size: CP.SectionTitle.arrowSize, color: C.labelTertiary)
                        } else {
                            Color.clear.frame(width: CP.EpisodeRow.moreTouch)
                        }  // 给“•••”留位置
                    }
                }
            }
            .padding(.horizontal, m)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([title] + meta).joined(separator: "，") + "，点按进入系列详情")
        .accessibilityAddTraits(.isButton)
    }

    private func texts(lines: Int?) -> some View {
        VStack(alignment: .leading, spacing: CP.SeriesRow.metaGap) {
            Text(title).zFont(S.listRowTitle).foregroundStyle(C.labelPrimary).lineLimit(lines).multilineTextAlignment(.leading)
            ForEach(meta, id: \.self) { Text($0).zFont(S.caption).foregroundStyle(C.labelSecondary) }
        }
    }
}

// MARK: - 列表行 H（搜索结果）

struct ListRowView: View {
    var card: SeriesCard
    var action: () -> Void
    @Environment(\.windowWidth) private var W
    var body: some View {
        let m = Layout.pageMargin(W)
        Button(action: action) {
            HStack(spacing: CP.ListRow.gap) {
                CoverImage(path: card.coverPath, colorId: card.id, radius: Tok.Radius.thumbnail)
                    .frame(width: CP.ListRow.thumbWidth, height: CP.ListRow.thumbHeight)
                VStack(alignment: .leading, spacing: Tok.Space.textGap) {
                    Text(card.title).zFont(S.listRowTitle).foregroundStyle(C.labelPrimary).lineLimit(2).multilineTextAlignment(.leading)
                    Text(seriesStatusText(card.status)).zFont(S.caption).foregroundStyle(C.labelSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, CP.ListRow.paddingV)
            .frame(minHeight: CP.ListRow.minHeight)
            .padding(.horizontal, m)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .overlay(alignment: .bottom) { Separator().padding(.leading, m + CP.ListRow.thumbWidth + CP.ListRow.gap) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(card.title)，\(seriesStatusText(card.status))，点按进入系列详情")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - 播放胶囊

struct PlayPill: View {
    var state: PillState
    var ratio: Double
    var playing: Bool
    var onIcon: () -> Void
    var onBody: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onIcon) {
                Group {
                    if playing {
                        ZIcon(name: "pause", size: CP.EpisodeRow.playIcon)
                    } else if state.kind == .done {
                        ZIcon(name: "refresh", size: CP.EpisodeRow.replayIcon)
                    } else {
                        ZIcon(name: "play", size: CP.EpisodeRow.playIcon)
                    }
                }
                .frame(width: CP.EpisodeRow.pillIconTouch, height: CP.EpisodeRow.pillHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(playing ? "暂停" : state.kind == .done ? "已听完，点按重新播放" : "播放，\(state.text)")
            Button(action: onBody) {
                HStack(spacing: CP.EpisodeRow.pillGap) {
                    if state.kind == .half && !playing || state.kind == .half {
                        ZStack(alignment: .leading) {
                            Capsule().fill(C.separator)
                            Capsule().fill(C.labelPrimary).frame(width: CP.EpisodeRow.miniBarWidth * ratio)
                        }
                        .frame(width: CP.EpisodeRow.miniBarWidth, height: CP.EpisodeRow.miniBarHeight)
                    }
                    Text(state.text).zFont(S.buttonText).foregroundStyle(C.labelPrimary).monospacedDigit().lineLimit(1)
                }
                .padding(.trailing, CP.EpisodeRow.pillPaddingH)
                .frame(minHeight: CP.EpisodeRow.pillHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityHidden(true)
        }
        .background(Capsule().fill(C.backgroundSecondary))
        .fixedSize()
    }
}

/// 下载状态图标：已下载、下载中（进度环，环内方块，点＝暂停）、已暂停（灰色环两竖线，点＝继续）。
struct DownloadIndicator: View {
    var status: DlStatus?
    var ratio: Double
    var onTap: () -> Void
    var body: some View {
        switch status {
        case .done:
            ZIcon(name: "arrow-down-circle", size: CP.EpisodeRow.statusIcon, color: C.labelSecondary)
                .accessibilityLabel("已下载").accessibilityHidden(false)
        case .queued, .downloading:
            Button(action: onTap) { ProgressRing(ratio: ratio, paused: false).minTouch() }
                .buttonStyle(PressableStyle()).accessibilityLabel("下载中，点按暂停")
        case .paused:
            Button(action: onTap) { ProgressRing(ratio: ratio, paused: true).minTouch() }
                .buttonStyle(PressableStyle()).accessibilityLabel("已暂停，点按继续下载")
        case nil:
            EmptyView()
        }
    }
}

/// 下载进度环：系统的圆形进度（Gauge）；中间是系统图标（下载中：停止方块；已暂停：暂停）。
struct ProgressRing: View {
    var ratio: Double
    var paused: Bool
    var size: CGFloat = CP.EpisodeRow.ring
    var body: some View {
        Gauge(value: max(CP.EpisodeRow.ringMinArc, min(ratio, 1))) {
            EmptyView()
        } currentValueLabel: {
            Image(systemName: paused ? "pause.fill" : "stop.fill")
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(paused ? C.labelTertiary : C.labelPrimary)
        // 系统这种圆环的默认尺寸较大（为小组件设计），按我们要的直径等比缩小
        .scaleEffect(size / CP.EpisodeRow.gaugeNative)
        .frame(width: size, height: size)
    }
}

/// “•••”按钮（20pt labelTertiary，触控区 44）。报告自己在屏幕上的位置，供弹出菜单定位。
struct MoreButton: View {
    var label = "更多操作"
    var items: () -> [[MenuItem]]
    var body: some View {
        NativeMenu(items: items) {
            // 宽度可收缩：一行放不下时（如最近页带下载图标的行）点按区先让出来，最窄到图标本身
            ZIcon(name: "ellipsis-horizontal", size: CP.EpisodeRow.moreIcon, color: C.labelTertiary)
                .frame(
                    minWidth: CP.EpisodeRow.moreIcon, maxWidth: CP.EpisodeRow.moreTouch, minHeight: CP.EpisodeRow.moreTouch,
                    maxHeight: CP.EpisodeRow.moreTouch
                )
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}

// MARK: - 空状态、错误、提示条

/// 空状态与加载失败：系统的 ContentUnavailableView，图标按情况选系统图标。
struct EmptyStateView: View {
    var text: String
    var retry: (() -> Void)? = nil
    var body: some View {
        ContentUnavailableView {
            Label(text, systemImage: Self.symbol(for: text))
        } actions: {
            if let retry { Button("重试", action: retry).buttonStyle(.bordered) }
        }
    }

    static func symbol(for text: String) -> String {
        switch text {
        case _ where text.contains("收听记录"): "clock"
        case _ where text.contains("收藏"): "bookmark"
        case _ where text.contains("下载"): "arrow.down.circle"
        case _ where text.contains("未找到") || text.contains("搜索"): "magnifyingglass"
        case _ where text.contains("下架"): "xmark.circle"
        case _ where text.contains("无法"): "wifi.exclamationmark"
        default: "books.vertical"
        }
    }
}

/// 重试等按钮：系统的带边框按钮。
struct RetryButton: View {
    var title: String
    var action: () -> Void
    var body: some View {
        Button(title, action: action).buttonStyle(.bordered).controlSize(.large)
    }
}

struct BannerView: View {
    var text: String
    var actions: [(String, () -> Void)]
    @Environment(\.windowWidth) private var W
    var body: some View {
        HStack(spacing: CP.Banner.paddingH) {
            Text(text).zFont(S.bannerText).foregroundStyle(C.labelSecondary).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(actions.indices, id: \.self) { i in
                Button(action: actions[i].1) {
                    Text(actions[i].0).zFont(S.bannerAction).foregroundStyle(C.labelPrimary).frame(minHeight: CP.Banner.height)
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(.horizontal, CP.Banner.paddingH)
        .frame(minHeight: CP.Banner.height)
        .background(RoundedRectangle(cornerRadius: CP.Banner.radius, style: .continuous).fill(C.backgroundSecondary))
        .padding(.horizontal, Layout.pageMargin(W))
    }
}
