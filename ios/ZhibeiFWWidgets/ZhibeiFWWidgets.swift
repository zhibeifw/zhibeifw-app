import SwiftUI
import WidgetKit
import AppIntents

/// 智悲佛网的小组件：继续播放、最新课程、编辑精选、收藏的课程。
/// 数据都是 App 写好放在共享目录里的（WidgetStore），这里只读、只画。App 里内容变了会让系统刷新，这里不自己定时刷新。
@main
struct ZhibeiFWWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        LatestWidget()
        FeaturedWidget()
        FavoritesWidget()
    }
}

// MARK: - 数据

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: .now, snap: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let s = WidgetStore.read()
        // 添加小组件时的预览：还没有数据就用示例
        completion(SnapshotEntry(date: .now, snap: context.isPreview && s == WidgetSnapshot() ? .sample : s))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let s = WidgetStore.read()
        WidgetLog.note("小组件读到：在播 \(s.nowPlaying?.item.seriesId ?? "无") / \(s.nowPlaying?.item.episodeId ?? "无") playing=\(s.nowPlaying?.playing ?? false)，最新 \(s.latest.count)，收藏 \(s.favorites.count)")
        completion(Timeline(entries: [SnapshotEntry(date: .now, snap: s)], policy: .never))
    }
}

extension WidgetSnapshot {
    /// 添加小组件时的预览用
    static var sample: WidgetSnapshot {
        let colors: [UInt32] = [0xFFD9691F, 0xFF3D7EBF, 0xFF6B4FA0, 0xFFD65C7A, 0xFF3F8F8F, 0xFF7A8B3C, 0xFF3F8F6B]
        let items = colors.enumerated().map { i, c in
            WidgetItem(seriesId: "s\(i)", seriesTitle: "课程名称", episodeId: "e\(i)", episodeTitle: "第 \(i + 1) 课", cover: nil, color: c)
        }
        return WidgetSnapshot(
            nowPlaying: WidgetNowPlaying(item: items[0], position: 1200, duration: 3600, playing: false, loaded: false),
            latest: items, featured: Array(items.prefix(6)), favorites: Array(items.prefix(6)))
    }
}

// MARK: - 继续播放

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.nowPlaying, provider: SnapshotProvider()) { e in
            NowPlayingView(np: e.snap.nowPlaying)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("继续播放")
        .description("接着听正在播放的一集。")
        // 小号只放得下一集的一点信息，不做（用户定）；锁屏一行
        .supportedFamilies([.systemMedium, .systemLarge, .accessoryRectangular])
    }
}

struct NowPlayingView: View {
    let np: WidgetNowPlaying?
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let np {
            content(np).widgetURL(
                (np.loaded ? WidgetLink.player(seriesId: np.item.seriesId) : WidgetLink.series(np.item.seriesId)).url)
        } else {
            EmptyWidget(text: "还没有在听的课程")
        }
    }

    @ViewBuilder private func content(_ np: WidgetNowPlaying) -> some View {
        let i = np.item
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(i.seriesTitle).font(.headline).lineLimit(1)
                Text(i.episodeTitle ?? "").font(.caption).lineLimit(1)
                ProgressView(value: fraction(np)).tint(.primary)
            }
        case .systemMedium:
            HStack(spacing: 12) {
                // 封面在左边上下居中
                Cover(item: i, radius: 10).frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    Text(i.seriesTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    Text(i.episodeTitle ?? "").font(.headline).lineLimit(2)
                    Spacer(minLength: 0)
                    ProgressBar(value: fraction(np))
                    HStack {
                        Text(remaining(np)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        PlayButton(np: np, size: 36)
                    }
                }
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                Cover(item: i, radius: 12)
                Text(i.seriesTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.top, 4)
                Text(i.episodeTitle ?? "").font(.title3.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 0)
                ProgressBar(value: fraction(np))
                HStack {
                    Text(remaining(np)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    PlayButton(np: np, size: 48)
                }
            }
        }
    }

    private func fraction(_ np: WidgetNowPlaying) -> Double {
        np.duration > 0 ? min(1, max(0, np.position / np.duration)) : 0
    }

    private func remaining(_ np: WidgetNowPlaying) -> String {
        guard np.duration > 0 else { return "" }
        let m = Int(((np.duration - np.position) / 60).rounded(.up))
        return m <= 0 ? "即将听完" : "剩余 \(m) 分钟"
    }
}

/// 播放 / 暂停：在 App 的进程里执行，不打开 App；动作带上点了以后要切到的状态
struct PlayButton: View {
    let np: WidgetNowPlaying
    let size: CGFloat

    var body: some View {
        Button(intent: SetPlayingIntent(episodeId: np.item.episodeId ?? "", play: !np.playing)) {
            Image(systemName: np.playing ? "pause.circle.fill" : "play.circle.fill")
                .resizable().scaledToFit().frame(width: size, height: size)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(np.playing ? "暂停" : "播放")
    }
}

struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15))
                Capsule().fill(Color.primary).frame(width: g.size.width * value)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

// MARK: - 最新课程

struct LatestWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.latest, provider: SnapshotProvider()) { e in
            LatestView(items: e.snap.latest, nowPlaying: e.snap.nowPlaying)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("最新课程")
        .description("新课程里每门课的最新一集，点一下就播放。")
        // 中号 3 门、大号 7 门；不做小号（只放得下一门，用户定）
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct LatestView: View {
    let items: [WidgetItem]
    /// 正在播的是其中一集时，那一行显示暂停，点了暂停 / 接着播（和“继续播放”的按钮一样）
    let nowPlaying: WidgetNowPlaying?
    @Environment(\.widgetFamily) private var family

    private func rows(_ n: Int) -> some View {
        VStack(spacing: family == .systemLarge ? 8 : 6) {
            ForEach(items.prefix(n), id: \.self) { i in
                // 正在播的那一集显示暂停，点了暂停；点别的行开始播那一集
                let id = i.episodeId ?? ""
                let on = nowPlaying.map { $0.loaded && $0.playing && $0.item.episodeId == id } ?? false
                Button(intent: SetPlayingIntent(episodeId: id, play: !on)) { LatestRow(item: i, playing: on) }
                    .buttonStyle(.plain)
            }
        }
    }

    var body: some View {
        if items.isEmpty {
            EmptyWidget(text: "暂时没有新课程")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Header(title: "新课程")
                // 放得下几行就放几行：各机型小组件高度不同（iPad mini 比 iPhone 矮）。
                // 系统的 ViewThatFits 从多到少试，用第一个放得下的（中号最多 3 行、大号最多 7 行）
                ViewThatFits(in: .vertical) {
                    ForEach((1...(family == .systemLarge ? 7 : 3)).reversed(), id: \.self) { n in
                        rows(n)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct LatestRow: View {
    let item: WidgetItem
    let playing: Bool

    var body: some View {
        HStack(spacing: 10) {
            Cover(item: item, radius: 5).frame(width: 56)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.seriesTitle).font(.footnote.weight(.semibold)).lineLimit(1)
                Text("更新至 \(item.episodeTitle ?? "")").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill").font(.title3)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(playing ? "暂停" : "播放") \(item.seriesTitle) \(item.episodeTitle ?? "")")
    }
}

// MARK: - 编辑精选、收藏的课程

struct FeaturedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.featured, provider: SnapshotProvider()) { e in
            CoverGridView(title: "编辑精选", items: e.snap.featured, empty: "暂时没有编辑精选")
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("编辑精选")
        .description("编辑精选的课程，点封面进入课程。")
        // 小号只放得下一个封面，不做（用户定）
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct FavoritesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.favorites, provider: SnapshotProvider()) { e in
            CoverGridView(title: "收藏的课程", items: e.snap.favorites, empty: "还没有收藏的课程")
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("收藏的课程")
        .description("收藏的课程，点封面进入课程。")
        // 小号只放得下一个封面，不做（用户定）
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

/// 课程封面：点封面打开 App 进这门课的课程页
struct CoverGridView: View {
    let title: String
    let items: [WidgetItem]
    let empty: String
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if items.isEmpty {
            EmptyWidget(text: empty)
        } else {
            // 一行 3 个；放得下几行就放几行（各机型小组件宽高不同）：系统的 ViewThatFits 从多到少试，
            // 中号最多 1 行、大号最多 3 行；从上往下排，不满时空在下面（和系统的小组件一样）
            let most = min(family == .systemLarge ? 3 : 1, (items.count + 2) / 3)
            VStack(alignment: .leading, spacing: 0) {
                Header(title: title)
                ViewThatFits(in: .vertical) {
                    ForEach((1...most).reversed(), id: \.self) { n in grid(n) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func grid(_ rows: Int) -> some View {
        let cols = 3
        return Grid(horizontalSpacing: 10, verticalSpacing: 12) {
            ForEach(0..<rows, id: \.self) { r in
                GridRow(alignment: .top) {
                    ForEach(0..<cols, id: \.self) { c in
                        let k = r * cols + c
                        if k < items.count {
                            Link(destination: WidgetLink.series(items[k].seriesId).url) { CoverTile(item: items[k]) }
                        } else {
                            Color.clear.gridCellUnsizedAxes([.vertical])
                        }
                    }
                }
            }
        }
    }
}

struct CoverTile: View {
    let item: WidgetItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Cover(item: item, radius: 6)
            Text(item.seriesTitle).font(.caption.weight(.semibold)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 公用

/// 16:9 封面；没有图时是这门课的占位色
struct Cover: View {
    let item: WidgetItem
    let radius: CGFloat

    var body: some View {
        // 有图只放图、没图才放色块（图叠在色块上时，主屏幕“着色”样式会把整块当一个形状染色，变成白块）
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let u = WidgetStore.coverURL(item.cover), let img = UIImage(contentsOfFile: u.path) {
                    // “着色”“透明”样式下按苹果的做法显示成灰度，不让系统染成一种颜色
                    Image(uiImage: img).resizable().widgetAccentedRenderingMode(.desaturated).scaledToFill()
                } else {
                    Color(argb: item.color)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct Header: View {
    let title: String

    var body: some View {
        Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.bottom, 6)
    }
}

/// 没有内容时：一句话，点一下打开 App
struct EmptyWidget: View {
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Text("智悲佛网").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.subheadline).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Color {
    init(argb: UInt32) {
        self.init(
            red: Double((argb >> 16) & 0xFF) / 255, green: Double((argb >> 8) & 0xFF) / 255, blue: Double(argb & 0xFF) / 255,
            opacity: Double((argb >> 24) & 0xFF) / 255)
    }
}
