import SwiftUI

/// 资料库：最近播放、收藏（iPhone 的“已下载”电视上没有）。
struct TVLibraryHubView: View {
    var body: some View {
        List {
            NavigationLink(value: TVRoute.recent) { Label("最近播放", systemImage: "clock") }
            NavigationLink(value: TVRoute.favorites) { Label("收藏", systemImage: "bookmark") }
        }
        .frame(maxWidth: 900)
    }
}

/// 最近收听：选一集接着播；长按：标记已听完、前往课程、删除记录。上面有“清空”。
struct TVRecentView: View {
    @Environment(AppCore.self) private var core
    @Environment(TVModel.self) private var model
    @State private var rows: [RecentRow]

    /// 进页面时就读好（第一帧就要有能选中的东西，返回键才不会被当成退出 App）。
    init(store: Store) { _rows = State(initialValue: (try? store.loadRecent(limit: 200)) ?? []) }

    var body: some View {
        Group {
            if rows.isEmpty {
                Text("暂无收听记录").foregroundStyle(.secondary).focusable()
            } else {
                // “清空”也是列表里的一行（单独一组，放在记录上面）：选中时放大由系统的列表留空间，不会和记录重叠。
                // 放在列表外面不行：tvOS 列表行选中时会放大、浮出列表的边界，压到外面的东西
                List {
                    Section {
                        Button(role: .destructive, action: confirmClear) {
                            Label("清空最近播放", systemImage: "trash")
                        }
                    }
                    Section {
                        ForEach(rows) { r in row(r) }
                    } header: {
                        Text("\(rows.count) 条记录")
                    }
                }
            }
        }
        .navigationTitle("最近播放")
        .task(id: [core.catalogVersion, core.progressVersion]) {
            rows = (try? core.store.loadRecent(limit: 200)) ?? []
        }
    }

    private func row(_ r: RecentRow) -> some View {
        let p = core.player
        let prog = liveProgress(
            currentId: p?.current?.episodeId, position: p?.position ?? 0, duration: p?.duration ?? 0,
            active: p?.looksPlaying ?? false, episodeId: r.episodeId, fromDb: r.progress)
        return Button {
            core.playFromRecent(r, open: true)
        } label: {
            HStack(spacing: 32) {
                CoverImage(path: r.coverPath, colorId: r.seriesId, radius: 8)
                    .frame(width: 192, height: TVLayout.coverHeight(192))
                VStack(alignment: .leading, spacing: 6) {
                    Text(r.epTitle).lineLimit(2)
                    Text(r.seriesTitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(r.gone ? "已下架" : progressText(prog, knownDuration: r.epDuration))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            MarkCompletedButton(episodeId: r.episodeId, seriesId: r.seriesId, completed: prog?.completed ?? false)
            Button {
                model.goToSeries(r.seriesId)
            } label: {
                Label("前往课程", systemImage: "arrow.forward.circle")
            }
            Button(role: .destructive) {
                core.hideRecent(r.episodeId)
            } label: {
                Label("删除记录", systemImage: "trash")
            }
        }
    }

    /// 和 iPhone 同样的确认文字。
    private func confirmClear() {
        core.alert = AlertSpec(
            title: "清空最近列表？", message: "列表中的记录会被移除。各课程的收听进度、已听完标记不受影响。",
            buttons: [
                AlertButton(title: "取消", role: .cancel),
                AlertButton(title: "清空", role: .destructive) { core.clearRecent() },
            ])
    }
}

/// 收藏：选一门课进课程页；长按：取消收藏。
struct TVFavoritesView: View {
    @Environment(AppCore.self) private var core
    @State private var rows: [FavoriteRow]

    init(store: Store) { _rows = State(initialValue: (try? store.loadFavorites()) ?? []) }

    var body: some View {
        Group {
            if rows.isEmpty {
                Text("还没有收藏的课程").foregroundStyle(.secondary).focusable()
            } else {
                ScrollView(.vertical) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(TVLayout.smallCardWidth), spacing: TVLayout.cardGap), count: 4),
                        alignment: .leading, spacing: 60
                    ) {
                        ForEach(rows) { f in
                            TVSeriesCard(
                                card: SeriesCard(id: f.id, title: f.title, coverPath: f.coverPath, status: f.status ?? ""),
                                width: TVLayout.smallCardWidth,
                                onRemoveFavorite: { core.removeFavorite(f.id) }
                            )
                        }
                    }
                    .padding(TVLayout.pageMargin)
                }
            }
        }
        .navigationTitle("收藏")
        .task(id: [core.catalogVersion, core.favoritesVersion]) {
            rows = (try? core.store.loadFavorites()) ?? []
        }
    }
}
