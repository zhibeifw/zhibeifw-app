import SwiftUI

/// 课程页：左边封面、课程名、简介、收藏、排序；右边各集列表。选一集开始播放并打开播放页。
/// 列表默认最旧的在上面（第 1 课在最上面），按一下排序按钮换成最新的在上面，再按一下换回；只影响显示，自动接下一集始终按课程顺序。
struct TVSeriesView: View {
    @Environment(AppCore.self) private var core
    let seriesId: String
    @State private var details: SeriesDetails
    /// 默认最旧到最新（第 1 课在最上面，和 iPhone 一样）；只在这一页有效，不记住
    @State private var oldestFirst = true

    /// 进页面时就读好（同分类页：第一帧就要有能选中的东西，返回键才不会被当成退出 App）。
    init(seriesId: String, store: Store) {
        self.seriesId = seriesId
        _details = State(initialValue: store.loadSeriesDetails(seriesId))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            switch details {
            case .ready(let h, let episodes):
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 24) {
                        CoverImage(path: h.coverPath, colorId: h.id, radius: TVLayout.coverRadius)
                            .frame(width: 560, height: TVLayout.coverHeight(560))
                        Text(h.title).font(.title2).fontWeight(.semibold).lineLimit(3)
                        HStack {
                            if let category = h.categoryName {
                                NavigationLink(value: TVRoute.category(h.categoryId)) {
                                    Text(category).lineLimit(1)
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .accessibilityLabel("分类：\(category)，查看全部课程")
                            }
                            Text(seriesInfoText(category: false, count: episodes.count, status: h.status))
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        // 收藏、排序并排一行。和播放页的“课程名 ›”一样：系统灰底按钮、胶囊形；书签图标和 iPhone 一样（收藏后是实心）。
                        // 两个按钮一个逻辑：按一下就切换，按钮上显示现在的状态，不弹选项单
                        HStack(spacing: 24) {
                            Button {
                                core.toggleFavorite(h.id, title: h.title, coverPath: h.coverPath)
                            } label: {
                                Label(h.favorited ? "已收藏" : "收藏", systemImage: h.favorited ? "bookmark.fill" : "bookmark")
                            }
                            Button {
                                oldestFirst.toggle()
                            } label: {
                                Label(oldestFirst ? "从旧到新" : "从新到旧", systemImage: oldestFirst ? "arrow.up.arrow.down.circle" : "arrow.up.arrow.down.circle.fill")
                            }
                            .accessibilityLabel(oldestFirst ? "排序：从旧到新" : "排序：从新到旧")
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        if let d = h.description, !d.isEmpty {
                            NavigationLink {
                                ScrollView { Text(d).frame(maxWidth: .infinity, alignment: .leading).padding(TVLayout.pageMargin).focusable() }
                                    .navigationTitle("课程简介")
                            } label: {
                                Text(d).font(.callout).lineLimit(3)
                            }
                            .accessibilityLabel("课程简介，" + d)
                        }
                    }
                }
                .frame(width: 560, alignment: .leading)
                VStack(alignment: .leading, spacing: 24) {
                    Text("全部课程").font(.headline).accessibilityAddTraits(.isHeader)
                    List(oldestFirst ? episodes : episodes.reversed()) { e in TVEpisodeRow(episode: e, ctx: .series(seriesId)) }
                }
            case .readFailed:
                VStack {
                    Text("课程读取失败")
                    Button("重试", action: reload)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .gone(let title, let favorited):
                Group {
                    if favorited {
                        UnavailableCourseView(title: title, favorited: true) { core.removeFavorite(seriesId) }
                            .focusSection()
                    } else {
                        UnavailableCourseView(title: title, favorited: false) {}
                            .focusable()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, TVLayout.pageMargin)
        // 目录、进度、收藏变了就重读
        .task(id: [core.catalogVersion, core.progressVersion, core.favoritesVersion]) { reload() }
    }

    private func reload() {
        details = core.store.loadSeriesDetails(seriesId)
    }
}

/// 一集的行：播放状态、集名，右边是实时进度与听完标记按钮。
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
        HStack {
            Button {
                core.playAndOpen(episode.id, ctx: ctx)
            } label: {
                HStack(spacing: 24) {
                    PlaybackLoadingView(loading: isCurrent && (p?.loadingPlayback ?? false)) {
                        if isCurrent, let p, p.looksPlaying {
                            AudioWaveformIcon(player: p)
                        } else {
                            Image(systemName: prog?.completed == true ? "arrow.clockwise" : "play.fill")
                        }
                    }
                    .accessibilityHidden(true)
                    Text(episode.title).lineLimit(2)
                    Spacer()
                    Text(pillState(prog, knownDuration: episode.epDuration ?? 0).text)
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.bordered)
            MarkCompletedButton(episodeId: episode.id, seriesId: episode.seriesId, completed: prog?.completed ?? false)
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
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
            Label(completed ? "标记为未听完" : "标记为已听完", systemImage: completed ? "rectangle.badge.minus" : "rectangle.badge.checkmark")
        }
    }
}
