import SwiftUI
import WidgetKit
import AppIntents

/// 智悲佛网的小组件：继续播放、最新课程。iPhone / iPad 和 Mac 共用这一份（Mac 没有锁屏小组件）。
/// 数据是 App 写好放在共享目录里的（WidgetStore）。App 里内容变了会让系统刷新；另外每 2 小时左右小组件自己取一次新课程（WidgetCatalog），App 很久没打开也能更新。
@main
struct ZhibeiFWWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        LatestWidget()
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

    /// 每 2 小时左右让系统再来一次：到时候（距上次检查够 2 小时）小组件自己取一次新课程（WidgetCatalog）。
    /// 什么时候真的来由系统定；App 里内容变了也会让系统马上重画
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        Task {
            var s = WidgetStore.read()
            if WidgetCatalog.due(s), let fresh = await WidgetCatalog.refresh(s) { s = fresh }
            WidgetLog.note(
                "小组件读到：在播 \(s.nowPlaying?.item.seriesId ?? "无") / \(s.nowPlaying?.item.episodeId ?? "无") playing=\(s.nowPlaying?.playing ?? false)，最新 \(s.latest.count)"
            )
            completion(
                Timeline(entries: [SnapshotEntry(date: .now, snap: s)], policy: .after(Date().addingTimeInterval(WidgetCatalog.interval))))
        }
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
            latest: items)
    }
}

// MARK: - 继续播放

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.nowPlaying, provider: SnapshotProvider()) { e in
            NowPlayingView(np: e.snap.nowPlaying)
                #if os(visionOS)
                .padding(WidgetDesign.visionHitGap)
                #endif
                .containerBackground(for: .widget) { Color.widgetBackground }
        }
        .configurationDisplayName("继续播放")
        .description("接着听正在播放的一集。")
        .supportedFamilies([.systemSmall])
        #if os(visionOS)
        .contentMarginsDisabled()
        #endif
    }
}

struct NowPlayingView: View {
    let np: WidgetNowPlaying?

    var body: some View {
        if let np {
            VStack(alignment: .leading, spacing: 6) {
                Cover(item: np.item, radius: 10)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(np.item.seriesTitle)
                            .font(.caption.weight(.semibold)).lineLimit(1)
                        Text(np.item.episodeTitle ?? "")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    PlayButton(np: np)
                }
            }
        } else {
            EmptyWidget(text: "还没有在听的课程")
        }
    }
}

/// 播放 / 暂停：在 App 的进程里执行，不打开 App；动作带上点了以后要切到的状态
struct PlayButton: View {
    let np: WidgetNowPlaying
    var body: some View {
        Button(intent: SetPlayingIntent(episodeId: np.item.episodeId ?? "", play: !np.playing)) {
            PlayProgressSymbol(playing: np.playing, progress: progressRatio(np.position, np.duration))
                .modifier(VisionWidgetHitTarget())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(np.playing ? "暂停" : "播放")
    }
}

/// 圆环由系统Gauge绘制，中心只放播放状态图标；进度取共享快照，不在小组件内推算。
struct PlayProgressSymbol: View {
    let playing: Bool
    let progress: Double
    var diameter: CGFloat = WidgetDesign.playProgressDiameter

    var body: some View {
        Gauge(value: progress) {
            Text("收听进度")
        } currentValueLabel: {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.title2)
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(Color.primary)
        .frame(width: WidgetDesign.gaugeNative, height: WidgetDesign.gaugeNative)
        .scaleEffect(diameter / WidgetDesign.gaugeNative)
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

// MARK: - 最新课程

struct LatestWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.latest, provider: SnapshotProvider()) { e in
            LatestView(items: e.snap.latest, nowPlaying: e.snap.nowPlaying)
                .containerBackground(for: .widget) { Color.widgetBackground }
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

    private var rowSpacing: CGFloat {
        #if os(visionOS)
        WidgetDesign.visionHitGap
        #else
        family == .systemLarge ? 8 : 6
        #endif
    }

    private func rows(_ n: Int) -> some View {
        VStack(spacing: rowSpacing) {
            ForEach(items.prefix(n), id: \.self) { i in
                // 正在播的那一集显示暂停，点了暂停；点别的行开始播那一集
                let id = i.episodeId ?? ""
                let on = nowPlaying.map { $0.loaded && $0.playing && $0.item.episodeId == id } ?? false
                let current = nowPlaying.flatMap { $0.item.episodeId == id ? $0 : nil }
                let progress = current.map { progressRatio($0.position, $0.duration) } ?? i.progress ?? 0
                Button(intent: SetPlayingIntent(episodeId: id, play: !on)) { LatestRow(item: i, playing: on, progress: progress).modifier(VisionWidgetHitTarget()) }
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
    let progress: Double

    var body: some View {
        HStack(spacing: 10) {
            Cover(item: item, radius: 5).frame(width: 56)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.seriesTitle).font(.footnote.weight(.semibold)).lineLimit(1)
                Text("更新至 \(item.episodeTitle ?? "")").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            PlayProgressSymbol(playing: playing, progress: progress, diameter: WidgetDesign.latestPlayProgressDiameter)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(playing ? "暂停" : "播放") \(item.seriesTitle) \(item.episodeTitle ?? "")")
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
                if let u = WidgetStore.coverURL(item.cover), let img = Self.load(u) {
                    // “着色”“透明”样式下按苹果的做法显示成灰度，不让系统染成一种颜色
                    img.resizable().widgetAccentedRenderingMode(.desaturated).scaledToFill()
                } else {
                    Color(argb: item.color)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension Cover {
    static func load(_ u: URL) -> Image? {
        #if os(macOS)
            NSImage(contentsOf: u).map { Image(nsImage: $0) }
        #else
            UIImage(contentsOfFile: u.path).map { Image(uiImage: $0) }
        #endif
    }
}

extension Color {
    /// 小组件的底色：跟系统（浅色白、深色黑）
    static var widgetBackground: Color {
        #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
        #else
            Color(.systemBackground)
        #endif
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

private struct VisionWidgetHitTarget: ViewModifier {
    func body(content: Content) -> some View {
        #if os(visionOS)
        content.frame(minWidth: WidgetDesign.visionHitSize, minHeight: WidgetDesign.visionHitSize)
            .contentShape(Rectangle())
        #else
        content
        #endif
    }
}
