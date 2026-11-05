import SwiftUI

/// 课程页：左边封面、课程名、简介、收藏、排序；右边各集列表。选一集开始播放并打开播放页。
/// 列表默认最旧的在上面（第 1 课在最上面），“排序”可以换成最新的在上面；只影响显示，自动接下一集始终按课程顺序。
struct TVSeriesView: View {
    @Environment(AppCore.self) private var core
    let seriesId: String
    @State private var header: SeriesHeader?
    @State private var episodes: [EpisodeRow]
    @State private var loaded = true
    /// 默认最旧到最新（第 1 课在最上面，和 iPhone 一样）；只在这一页有效，不记住
    @State private var oldestFirst = true
    @State private var sortDialog = false

    /// 进页面时就读好（同分类页：第一帧就要有能选中的东西，返回键才不会被当成退出 App）。
    init(seriesId: String, store: Store) {
        self.seriesId = seriesId
        _header = State(initialValue: try? store.loadSeriesHeader(seriesId))
        _episodes = State(initialValue: (try? store.loadEpisodes(seriesId)) ?? [])
    }

    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            if let h = header {
                VStack(alignment: .leading, spacing: 24) {
                    CoverImage(path: h.coverPath, colorId: h.id, radius: TVLayout.coverRadius)
                        .frame(width: 560, height: TVLayout.coverHeight(560))
                    Text(h.title).font(.title2).fontWeight(.semibold).lineLimit(3)
                    Text(seriesInfoText(category: false, count: episodes.count, status: h.status))
                        .font(.callout).foregroundStyle(.secondary)
                    // 和播放页的“课程名 ›”一样：系统灰底按钮、胶囊形；书签图标和 iPhone 一样（收藏后是实心）
                    Button {
                        core.toggleFavorite(h.id, title: h.title, coverPath: h.coverPath)
                    } label: {
                        Label(h.favorited ? "已收藏" : "收藏", systemImage: h.favorited ? "bookmark.fill" : "bookmark")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    Button { sortDialog = true } label: {
                        Label("排序", systemImage: "arrow.up.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    if let d = h.description, !d.isEmpty {
                        Text(d).font(.callout).foregroundStyle(.secondary).lineLimit(8)
                    }
                }
                .frame(width: 560, alignment: .leading)
                List(oldestFirst ? episodes : episodes.reversed()) { e in TVEpisodeRow(episode: e, ctx: .series(seriesId)) }
            } else if loaded {
                Text("这门课已下架").focusable().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, TVLayout.pageMargin)
        // 排序：系统选项单，文字和 iPhone 的排序菜单一样
        .confirmationDialog("排序", isPresented: $sortDialog, titleVisibility: .visible) {
            Button((oldestFirst ? "" : "✓ ") + "按最新到最旧排序") { oldestFirst = false }
            Button((oldestFirst ? "✓ " : "") + "按最旧到最新排序") { oldestFirst = true }
            Button("取消", role: .cancel) {}
        }
        // 目录、进度、收藏变了就重读
        .task(id: [core.catalogVersion, core.progressVersion, core.favoritesVersion]) { reload() }
    }

    private func reload() {
        header = try? core.store.loadSeriesHeader(seriesId)
        episodes = (try? core.store.loadEpisodes(seriesId)) ?? []
        loaded = true
    }
}

/// 一集的行：集名，右边是进度（正在播放的用播放器的实时位置）。
struct TVEpisodeRow: View {
    @Environment(AppCore.self) private var core
    let episode: EpisodeRow
    let ctx: PlayContext

    var body: some View {
        let p = core.player
        let prog = liveProgress(
            currentId: p?.current?.episodeId, position: p?.position ?? 0, duration: p?.duration ?? 0,
            active: p?.looksPlaying ?? false, episodeId: episode.id, fromDb: episode.progress)
        let isCurrent = p?.current?.episodeId == episode.id
        Button {
            core.playAndOpen(episode.id, ctx: ctx)
        } label: {
            HStack(spacing: 24) {
                if isCurrent { Image(systemName: (p?.looksPlaying ?? false) ? "speaker.wave.2.fill" : "pause.fill") }
                Text(episode.title).lineLimit(2)
                Spacer()
                Text(progressText(prog, knownDuration: episode.epDuration)).font(.callout).foregroundStyle(.secondary)
            }
        }
        // 长按确认键：和 iPhone 的“•••”菜单同样的文字
        .contextMenu {
            MarkCompletedButton(episodeId: episode.id, seriesId: episode.seriesId, completed: prog?.completed ?? false)
        }
    }
}

/// “标记为已听完 / 标记为未听完”。
struct MarkCompletedButton: View {
    @Environment(AppCore.self) private var core
    let episodeId: String
    let seriesId: String
    let completed: Bool

    var body: some View {
        Button {
            core.markCompleted(episodeId, seriesId: seriesId, completed: !completed)
        } label: {
            Label(completed ? "标记为未听完" : "标记为已听完", systemImage: "checkmark.circle")
        }
    }
}

/// 进度文字：已听完 / 剩余时间 / 时长。
func progressText(_ p: Prog?, knownDuration: Double?) -> String {
    if let p, p.completed { return "已听完" }
    if let p, p.duration > 0, p.position > 0 { return "剩余 " + clock(max(0, p.duration - p.position)) }
    if let d = knownDuration, d > 0 { return clock(d) }
    return ""
}
