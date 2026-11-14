import SwiftUI

struct WatchHomeView: View {
    @Environment(AppCore.self) private var core
    @Environment(WatchModel.self) private var model
    var body: some View {
        List {
            if model.upgrade.showsNotice {
                StoreUpgradeNotice(checker: model.upgrade)
                    .listRowBackground(Color.clear)
            }
            if core.autoUpdating { ProgressView("正在更新") }
            if core.syncFailed { Text("无法更新，显示上次内容").font(.footnote).foregroundStyle(.secondary) }
            if !core.home.ongoing.isEmpty {
                Section("最新课程") {
                    ForEach(core.home.ongoing) { card in
                        NavigationLink(value: WatchRoute.series(card.id)) {
                            WatchCourseLabel(
                                title: card.title, cover: card.coverPath, id: card.id,
                                subtitle: card.lastTitle.map { "更新至 " + $0 })
                        }
                    }
                }
            }
            if !core.home.featured.isEmpty {
                Section("编辑精选") {
                    ForEach(core.home.featured) { card in
                        NavigationLink(value: WatchRoute.series(card.id)) {
                            WatchCourseLabel(title: card.featureTitle ?? card.title, cover: card.coverPath, id: card.id)
                        }
                    }
                }
            }
            NavigationLink(value: WatchRoute.categories) { Label("浏览全部分类", systemImage: "square.grid.2x2") }
        }
        .navigationTitle("主页")
    }
}

struct WatchCategoriesView: View {
    @Environment(AppCore.self) private var core
    @State private var rows: [CategoryTile] = []
    var body: some View {
        List(rows) { row in
            NavigationLink(value: WatchRoute.category(row.id, row.name)) {
                Label(row.name, systemImage: SymbolName.all[resolveCategoryIcon(row.icon, id: row.id)] ?? SymbolName.all[DEFAULT_ICON]!)
                    .foregroundStyle(Tok.Color.onColor.color)
            }
            .listItemTint(resolveCategoryColor(row.color, id: row.id).color)
        }
        .navigationTitle("分类")
        .task(id: core.catalogVersion) { rows = (try? core.store.loadCategories()) ?? [] }
    }
}

struct WatchCategoryView: View {
    let id: String
    let title: String
    @Environment(AppCore.self) private var core
    @State private var courses: [SeriesCard] = []
    @State private var hasMore = true
    var body: some View {
        List {
            ForEach(courses) { card in
                NavigationLink {
                    WatchSeriesView(id: card.id)
                } label: {
                    WatchCourseLabel(
                        title: card.title, cover: card.coverPath, id: card.id,
                        subtitle: seriesStatusText(card.status))
                }
            }
            if hasMore { Button("加载更多", systemImage: "chevron.down") { load() } }
        }
        .overlay {
            if courses.isEmpty && !hasMore {
                Text("暂无课程")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(title)
        .task(id: core.catalogVersion) {
            courses = []; load()
        }
    }
    private func load() {
        let next = (try? core.store.loadCategorySeries(id, limit: 30, offset: courses.count)) ?? []
        courses += next
        hasMore = next.count == 30
    }
}

struct WatchSearchView: View {
    @Environment(AppCore.self) private var core
    @State private var text = ""
    @State private var submitted = ""
    @State private var result: Store.SearchResult?
    @State private var searching = false
    var body: some View {
        List {
            if searching { ProgressView("正在搜索") }
            if let result {
                if result.rows.isEmpty {
                    Text("未找到相关内容")
                } else {
                    if result.fallback { Text("已显示“\(result.matched)”的结果").font(.footnote) }
                    ForEach(result.rows) { row in
                        NavigationLink(row.title, value: WatchRoute.series(row.id))
                    }
                }
            }
        }
        .navigationTitle("搜索")
        .searchable(text: $text, prompt: "课程名或拼音")
        .onSubmit(of: .search) { submitted = normalizeText(text) }
        .onChange(of: text) { _, value in
            if value.count > MAX_QUERY_LENGTH { text = String(value.prefix(MAX_QUERY_LENGTH)) }
            if normalizeText(value).isEmpty { submitted = ""; result = nil }
        }
        .task(id: submitted) {
            guard !submitted.isEmpty else { searching = false; return }
            searching = true
            let query = submitted, store = core.store!
            let answer = await Task.detached(priority: .userInitiated) { try? store.searchSeries(query) }.value
            guard !Task.isCancelled else { return }
            result = answer
            searching = false
        }
    }
}

struct WatchSeriesView: View {
    let id: String
    @Environment(AppCore.self) private var core
    @Environment(WatchModel.self) private var model
    @State private var header: SeriesHeader?
    @State private var episodes: [EpisodeRow] = []
    @State private var oldestFirst = true
    @State private var loaded = false

    var body: some View {
        List {
            if let header {
                WatchCourseLabel(
                    title: header.title, cover: header.coverPath, id: id,
                    subtitle: seriesInfoText(category: false, count: episodes.count, status: header.status))
                if let text = header.description, !text.isEmpty {
                    NavigationLink {
                        ScrollView { Text(text).font(.body).padding() }.navigationTitle("课程简介")
                    } label: { Label("课程简介", systemImage: "text.alignleft") }
                }
                Section("全部课程") {
                    ForEach(oldestFirst ? episodes : episodes.reversed()) { row in
                        WatchEpisodeRow(
                            id: row.id, series: id, title: row.title, scope: .series,
                            progress: row.progress, duration: row.epDuration ?? 0, compactPlayback: true)
                    }
                }
            } else if loaded {
                ContentUnavailableView("课程已下架", systemImage: "xmark.circle")
            } else {
                ProgressView()
            }
        }
        .navigationTitle("课程")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    WatchSeriesActionsView(id: id, oldestFirst: $oldestFirst)
                } label: {
                    Image(systemName: "ellipsis")
                }.accessibilityLabel("课程选项")
            }
        }
        .task(id: model.versions) {
            header = try? core.store.loadSeriesHeader(id)
            episodes = (try? core.store.loadEpisodes(id)) ?? []
            loaded = true
        }
    }
}

struct WatchSeriesActionsView: View {
    let id: String
    @Binding var oldestFirst: Bool
    @Environment(AppCore.self) private var core
    @Environment(WatchModel.self) private var model
    @State private var header: SeriesHeader?
    @State private var categoryIcon: String?

    var body: some View {
        List {
            if let header {
                NavigationLink { WatchSeriesDownloadsView(series: id) } label: {
                    Label("下载", systemImage: "arrow.down.circle")
                }
                Button {
                    core.toggleFavorite(id, title: header.title, coverPath: header.coverPath)
                } label: {
                    Label(header.favorited ? "取消收藏" : "收藏", systemImage: header.favorited ? "bookmark.fill" : "bookmark")
                }
                Button {
                    oldestFirst.toggle()
                } label: {
                    Label(oldestFirst ? "从新到旧排序" : "从旧到新排序", systemImage: "arrow.up.arrow.down")
                }
                if let category = header.categoryName {
                    NavigationLink { WatchCategoryView(id: header.categoryId, title: category) } label: {
                        Label(category, systemImage: SymbolName.all[resolveCategoryIcon(categoryIcon, id: header.categoryId)] ?? SymbolName.all[DEFAULT_ICON]!)
                    }
                }
            }
        }
        .navigationTitle("课程选项")
        .task(id: model.versions) {
            header = try? core.store.loadSeriesHeader(id)
            categoryIcon = (try? core.store.loadCategories())?.first { $0.id == header?.categoryId }?.icon
        }
    }

}

private struct WatchDownloadListItem: Identifiable {
    let id: String
    let title: String
}

struct WatchSeriesDownloadsView: View {
    let series: String
    var downloadedOnly = false
    @Environment(AppCore.self) private var core
    @Environment(WatchModel.self) private var model
    @State private var rows: [WatchDownloadListItem] = []
    @State private var downloads: [String: DlRow] = [:]

    var body: some View {
        List {
            if !rows.isEmpty {
                Section { batchButton }
            } else if downloadedOnly {
                Text("暂无下载")
            }
            ForEach(rows) { row in
                WatchDownloadActionRows(
                    id: row.id, download: downloads[row.id], title: row.title,
                    playDownloaded: { core.playAndOpen(row.id, ctx: .library(series)) }
                ) {
                    model.confirm("删除此下载？", message: "保留收听进度；若正在播放此下载，将停止播放。") {
                        model.deleteDownloads([row.id])
                    }
                }
            }
        }
        .navigationTitle("下载")
        .task(id: model.versions) {
            let saved = (try? core.store.downloadsOfSeries(series)) ?? []
            downloads = Dictionary(uniqueKeysWithValues: saved.map { ($0.episodeId, $0) })
            if downloadedOnly {
                rows = saved.sorted { $0.pos < $1.pos }.map { WatchDownloadListItem(id: $0.episodeId, title: $0.episodeTitle) }
            } else {
                rows = ((try? core.store.loadEpisodes(series)) ?? []).map { WatchDownloadListItem(id: $0.id, title: $0.title) }
            }
        }
    }

    private var batchButton: some View {
        WatchBatchDownloadButton(ids: rows.map(\.id), series: series)
    }
}
