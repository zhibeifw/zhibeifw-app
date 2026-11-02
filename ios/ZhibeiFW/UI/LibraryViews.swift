import SwiftUI

/// 资料库标签：系统列表，三行进三个子页。
struct LibraryHubView: View {
    var body: some View {
        List {
            // 列表第一行上面那条线（系统 plain 列表默认会画）去掉，紧贴大标题不好看；行与行之间的线保留（同“音乐”App 的资料库）
            NavigationLink(value: Route.recent) { Label("最近播放", systemImage: "clock") }
                .listRowSeparator(.hidden, edges: .top)
            NavigationLink(value: Route.favorites) { Label("收藏", systemImage: "bookmark") }
            NavigationLink(value: Route.library) { Label("已下载", systemImage: "arrow.down.circle") }
        }
        .listStyle(.plain)
        .navigationTitle("资料库")
        .navigationBarTitleDisplayMode(.large)
    }
}

/// 最近。
struct RecentView: View {
    @Environment(AppModel.self) private var model
    @State private var rows: [RecentRow] = []

    var body: some View {
        PageScaffold(
            title: "最近播放", subtitle: rows.isEmpty ? nil : "\(rows.count) 条记录",
            trailing: {
                Button("清空") {
                    model.alert = AlertSpec(
                        title: "清空最近列表？", message: "列表中的记录会被移除。各课程的收听进度、已听完标记和已下载内容不受影响。",
                        buttons: [
                            AlertButton(title: "取消", role: .cancel),
                            AlertButton(title: "清空", role: .destructive) {
                                model.clearRecent()
                            },
                        ])
                }
                .disabled(rows.isEmpty)
            }
        ) {
            if rows.isEmpty {
                EmptyStateView(text: "暂无收听记录").padding(.top, Tok.Space.scale[6] * 4)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { r in
                        RecentRowView(row: r)
                    }
                }
            }
        }
        .task(id: [model.progressVersion, model.downloadsVersion]) { rows = (try? model.store.loadRecent()) ?? [] }
    }
}

/// 收藏夹。
struct FavoritesView: View {
    @Environment(AppModel.self) private var model
    @State private var rows: [FavoriteRow] = []

    var body: some View {
        PageScaffold(title: "收藏", subtitle: rows.isEmpty ? nil : "\(rows.count) 门课") {
            if rows.isEmpty {
                EmptyStateView(text: "暂无收藏").padding(.top, Tok.Space.scale[6] * 4)
            } else {
                LazyVStack(spacing: CP.SeriesRow.gap) {
                    ForEach(rows) { f in
                        SeriesRowView(
                            id: f.id, title: f.title, meta: [f.gone ? "已下架" : seriesStatusText(f.status)], coverPath: f.coverPath,
                            menu: {
                                [
                                    [
                                        MenuItem(title: "取消收藏", icon: "bookmark-outline", destructive: true) {
                                            model.removeFavorite(f.id)
                                        }
                                    ]
                                ]
                            }
                        ) { model.nav.push(.series(f.id)) }
                    }
                }
            }
        }
        .task(id: model.favoritesVersion) { rows = (try? model.store.loadFavorites()) ?? [] }
    }
}

/// 资料库第一层：下载过的课程，按添加先后倒序。
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var rows: [LibrarySeries] = []

    var body: some View {
        let lessons = rows.reduce(0) { $0 + $1.n }
        let doneAll = rows.reduce(0) { $0 + $1.done }
        let activeAny = model.downloads.items.values.contains { $0.status == .queued || $0.status == .downloading }
        let pausedAny = model.downloads.items.values.contains { $0.status == .paused }
        PageScaffold(title: "已下载", subtitle: rows.isEmpty ? nil : "\(rows.count) 门课 · " + libraryCountText(total: lessons, done: doneAll)) {
            if rows.isEmpty {
                EmptyStateView(text: "暂无下载").padding(.top, Tok.Space.scale[6] * 4)
            } else {
                VStack(spacing: CP.SeriesRow.gap) {
                    if activeAny || pausedAny {
                        HStack(spacing: CP.QuickPill.gap) {
                            topButton(activeAny ? "暂停全部" : "继续全部") {
                                if activeAny { model.downloads.pauseAll() } else { model.resumeDownloads(seriesId: nil) }
                            }
                            topButton("取消全部") { model.downloads.cancelSeries(nil) }
                        }
                        .padding(.horizontal, Tok.Space.pageMargin)
                    }
                    LazyVStack(spacing: CP.SeriesRow.gap) {
                        ForEach(rows) { s in
                            SeriesRowView(
                                id: s.seriesId, title: s.seriesTitle, meta: meta(s),
                                coverPath: s.coverPath,
                                localCover: model.files.coverFile(seriesId: s.seriesId), menu: { menuItems(s) }
                            ) { model.nav.push(.libraryCourse(s.seriesId)) }
                        }
                    }
                }
            }
        }
        .task(id: model.downloadsVersion) { rows = (try? model.store.loadLibrary()) ?? [] }
    }

    private func status(_ s: LibrarySeries) -> (active: Bool, paused: Bool) {
        let mine = model.downloads.items.values.filter { $0.seriesId == s.seriesId }
        return (mine.contains { $0.status == .queued || $0.status == .downloading }, mine.contains { $0.status == .paused })
    }

    private func meta(_ s: LibrarySeries) -> [String] {
        var m = libraryCountLines(total: s.n, done: s.done)
        if status(s).active { m.append("下载中…") }
        return m
    }

    /// 一门课的“•••”菜单：下载中 → 暂停、取消；已暂停 → 继续、取消；最后是删除下载（要确认）。
    private func menuItems(_ s: LibrarySeries) -> [[MenuItem]] {
        let st = status(s)
        var dl: [MenuItem] = []
        if st.active {
            dl.append(MenuItem(title: "暂停下载", icon: "pause-circle-outline") { model.downloads.pauseAll(seriesId: s.seriesId) })
        } else if st.paused {
            dl.append(MenuItem(title: "继续下载", icon: "arrow-down-circle-outline") { model.resumeDownloads(seriesId: s.seriesId) })
        }
        if st.active || st.paused {
            dl.append(MenuItem(title: "取消下载", icon: "close-circle-outline") { model.downloads.cancelSeries(s.seriesId) })
        }
        let del = MenuItem(title: "删除下载", icon: "trash-outline", destructive: true) {
            model.alert = AlertSpec(
                title: "删除“\(s.seriesTitle)”的下载？", message: "将删除这门课已下载的 \(s.done) 节内容。课程仍可在线收听，也可以重新下载。",
                buttons: [
                    AlertButton(title: "取消", role: .cancel),
                    AlertButton(title: "删除", role: .destructive) {
                        if let c = model.player.current, c.seriesId == s.seriesId { model.player.stopIfCurrent(c.episodeId) }
                        model.downloads.removeSeries(s.seriesId)
                    },
                ])
        }
        return dl.isEmpty ? [[del]] : [dl, [del]]
    }

    private func topButton(_ t: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).zFont(S.buttonText).foregroundStyle(C.labelPrimary)
                .frame(maxWidth: .infinity, minHeight: CP.QuickPill.height)
                .background(Capsule().fill(C.backgroundSecondary))
        }
        .buttonStyle(PressableStyle())
    }
}

/// 资料库第二层：这门课已下载的集，按课程顺序。
struct LibraryCourseView: View {
    var seriesId: String
    @Environment(AppModel.self) private var model
    @State private var rows: [LibraryEpisode] = []

    var body: some View {
        let title = rows.first?.row.seriesTitle ?? ""
        let downloading = rows.contains {
            [.queued, .downloading].contains(model.downloads.items[$0.row.episodeId]?.status ?? $0.row.state)
        }
        let done = rows.filter { (model.downloads.items[$0.row.episodeId]?.status ?? $0.row.state) == .done }.count
        PageScaffold(
            title: title, subtitle: rows.isEmpty ? nil : libraryCountText(total: rows.count, done: done) + (downloading ? " · 下载中" : "")
        ) {
            if rows.isEmpty {
                EmptyStateView(text: "暂无下载").padding(.top, Tok.Space.scale[6] * 4)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { r in
                        let e = EpisodeItem(
                            episodeId: r.row.episodeId, seriesId: r.row.seriesId, title: r.row.episodeTitle, progress: r.progress,
                            epDuration: nil, dlState: r.row.state)
                        EpisodeRowView(item: e, ctx: .library(seriesId), showDownloadedIcon: false) { it in
                            [
                                [model.markItem(it), model.goCourseItem(it.seriesId)],
                                model.downloadItems(for: it).map {
                                    var m = $0; if m.title == "删除下载" { m.destructive = true }; return m
                                },
                            ]
                        }
                    }
                }
            }
        }
        .task(id: [model.progressVersion, model.downloadsVersion]) {
            rows = (try? model.store.loadLibraryEpisodes(seriesId)) ?? []
        }
    }
}
