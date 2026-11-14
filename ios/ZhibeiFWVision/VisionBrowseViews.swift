import SwiftUI

struct VisionBrowseView: View {
    let section: VisionSection
    @Environment(AppCore.self) private var core
    @Environment(VisionModel.self) private var model
    @State private var categories: [CategoryTile] = []
    @State private var recent: [RecentRow] = []
    @State private var favorites: [FavoriteRow] = []
    @State private var query = ""
    @State private var submitted = ""
    @State private var results: Store.SearchResult?
    @State private var searching = false
    var body: some View {
        Group {
            if section == .home {
                VisionHomeView()
            } else if section == .categories {
                VisionCategoriesView(rows: categories)
            } else if section == .favorites {
                VisionFavoritesView(rows: favorites)
            } else {
                listContent
            }
        }

        .navigationTitle(section.rawValue)
        .toolbar {
            if section == .recent {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        core.alert = AlertSpec(
                            title: "清空最近列表？",
                            message: "列表中的记录会被移除。各课程的收听进度、已听完标记和已下载内容不受影响。",
                            buttons: [
                                AlertButton(title: "取消", role: .cancel),
                                AlertButton(title: "清空", role: .destructive) { core.clearRecent() },
                            ])
                    } label: { Text("清空").visionHitTarget() }
                    .disabled(recent.isEmpty)
                }
            }
        }
        .environment(\.defaultMinListRowHeight, Tok.Component.Vision.hitSize)
        .listRowSpacing(Tok.Component.Vision.hitGap)
        .modifier(VisionSearchModifier(enabled: section == .search, text: $query))
        .onSubmit(of: .search) { submitted = normalizeText(query) }
        .onChange(of: query) { _, value in
            if value.count > MAX_QUERY_LENGTH { query = String(value.prefix(MAX_QUERY_LENGTH)) }
            if normalizeText(value).isEmpty { submitted = ""; results = nil }
        }
        .task(id: submitted) {
            guard !submitted.isEmpty else { searching = false; return }
            searching = true
            let store = core.store!, query = submitted
            let result = await Task.detached { try? store.searchSeries(query) }.value
            guard !Task.isCancelled else { return }
            results = result; searching = false
        }
        .task(id: model.versions) {
            categories = (try? core.store.loadCategories()) ?? []
            recent = (try? core.store.loadRecent()) ?? []
            favorites = (try? core.store.loadFavorites()) ?? []
        }
    }
    private var listContent: some View {
        List {
            switch section {
            case .home, .categories, .favorites: EmptyView()
            case .recent:
                if recent.isEmpty { ContentUnavailableView("暂无收听记录", systemImage: "clock") }
                ForEach(recent) { row in
                    let player = core.player
                    let progress = liveProgress(
                        currentId: player?.current?.episodeId, position: player?.position ?? 0,
                        duration: player?.duration ?? 0, active: player?.isPlaying ?? false,
                        episodeId: row.id, fromDb: row.progress)
                    HStack(spacing: Tok.Component.Vision.hitGap) {
                        Button {
                            core.playFromRecent(row, open: false)
                        } label: {
                            HStack(spacing: Tok.Component.Vision.hitGap) {
                                VisionArtwork(path: row.coverPath)
                                VStack(alignment: .leading) {
                                    Text(row.seriesTitle).font(.headline)
                                    VisionEpisodeLabel(
                                        id: row.id, title: row.epTitle, progress: row.progress, duration: row.epDuration ?? 0, showsTime: false)
                                }
                                Spacer()
                                Text(pillState(progress, knownDuration: row.epDuration ?? 0).text)
                                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                            }.frame(maxWidth: .infinity, alignment: .leading).visionHitTarget()
                        }.buttonStyle(.plain)
                        Button {
                            model.showSeries(row.seriesId)
                        } label: {
                            Label("前往课程", systemImage: "arrow.right").visionHitTarget()
                        }
                        .buttonStyle(.bordered)
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("前往课程，" + row.seriesTitle)
                    }
                }
            case .search:
                if searching { ProgressView("正在搜索") }
                if let results {
                    if results.rows.isEmpty { ContentUnavailableView.search(text: submitted) }
                    if results.fallback { Text("已显示“\(results.matched)”的结果").foregroundStyle(.secondary) }
                    ForEach(results.rows) { row in
                        NavigationLink(value: VisionRoute.series(row.id)) {
                            VisionCourseLabel(
                                id: row.id, title: row.title, cover: row.coverPath,
                                subtitle: seriesStatusText(row.status)).visionHitTarget()
                        }
                    }
                }
            case .about: VisionAboutContent()
            }
        }
    }

}

private struct VisionSearchModifier: ViewModifier {
    let enabled: Bool
    @Binding var text: String
    func body(content: Content) -> some View {
        if enabled { content.searchable(text: $text, prompt: "课程名或拼音") } else { content }
    }
}

struct VisionCategoryView: View {
    let id: String
    let name: String
    @Environment(AppCore.self) private var core
    @State private var rows: [SeriesCard] = []
    @State private var more = true
    var body: some View {
        ScrollView {
            if rows.isEmpty && !more {
                Text("暂无课程")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(Tok.Component.Vision.pageMargin)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Tok.Component.Vision.cardWidth))], alignment: .leading) {
                ForEach(rows) { row in
                    VisionCourseCard(
                        id: row.id, title: row.title, cover: row.coverPath, subtitle: seriesStatusText(row.status), fillsWidth: true)
                }
            }
            .padding(Tok.Component.Vision.pageMargin)
            if more { Button(action: load) { Text("加载更多").visionHitTarget() } }
        }
        .navigationTitle(name)
        .task(id: core.catalogVersion) {
            rows = []; load()
        }
    }
    private func load() {
        let next = (try? core.store.loadCategorySeries(id, limit: 30, offset: rows.count)) ?? []
        rows += next; more = next.count == 30
    }
}

struct VisionSeriesView: View {
    let id: String
    @Environment(AppCore.self) private var core
    @Environment(VisionModel.self) private var model
    @State private var header: SeriesHeader?
    @State private var episodes: [EpisodeRow] = []
    @State private var oldestFirst = true
    var body: some View {
        List {
            if let header {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Tok.Component.Vision.sectionGap) {
                        courseArtwork(header)
                        courseInformation(header)
                    }
                    VStack(alignment: .leading, spacing: Tok.Component.Vision.cardGap) {
                        courseArtwork(header)
                        courseInformation(header)
                    }
                }
                .padding(.vertical)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .buttonStyle(.borderless)
                if let description = header.description {
                    DisclosureGroup { Text(description).foregroundStyle(.secondary) } label: { Text("课程简介").visionHitTarget() }
                }
                Text("全部课程")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                ForEach(oldestFirst ? episodes : episodes.reversed()) { row in
                    HStack(spacing: Tok.Component.Vision.hitGap) {
                        Button {
                            core.togglePlay(row.id, ctx: .series(id))
                        } label: {
                            VisionEpisodeLabel(id: row.id, title: row.title, progress: row.progress, duration: row.epDuration ?? 0)
                                .frame(maxWidth: .infinity, alignment: .leading).visionHitTarget()
                        }.buttonStyle(.plain)
                        Button {
                            core.markCompleted(row.id, seriesId: id, completed: row.progress?.completed != true)
                        } label: {
                            Label(row.progress?.completed == true ? "标记为未听完" : "标记为已听完",
                                  systemImage: row.progress?.completed == true ? "rectangle.badge.minus" : "rectangle.badge.checkmark")
                                .visionHitTarget()
                        }
                        .buttonStyle(.borderless)
                        .labelStyle(.iconOnly)
                        .help(row.progress?.completed == true ? "标记为未听完" : "标记为已听完")
                    }
                }
            } else {
                ContentUnavailableView("课程暂不可用", systemImage: "book.closed")
            }
        }
        .listStyle(.plain)
        .listRowSpacing(Tok.Component.Vision.hitGap)
        .navigationTitle("课程")
        .task(id: model.versions) {
            header = try? core.store.loadSeriesHeader(id); episodes = (try? core.store.loadEpisodes(id)) ?? []
        }
    }
    private func courseArtwork(_ header: SeriesHeader) -> some View {
        VisionArtwork(path: header.coverPath, large: true)
            .frame(width: Tok.Component.Vision.cardWidth)
            .clipShape(RoundedRectangle(cornerRadius: Tok.Radius.cardLarge))
    }
    private func courseInformation(_ header: SeriesHeader) -> some View {
        VStack(alignment: .leading, spacing: Tok.Component.Vision.cardGap) {
            Text(header.title).font(.largeTitle).bold().fixedSize(horizontal: false, vertical: true)
            if let category = header.categoryName {
                Button {
                    model.path.append(.category(header.categoryId, category))
                } label: {
                    HStack(spacing: Tok.Component.Vision.hitGap) {
                        Text(category)
                        Image(systemName: "chevron.right")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }.visionHitTarget()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .hoverEffect(.highlight)
            }
            Text(seriesInfoText(category: false, count: episodes.count, status: header.status))
                .foregroundStyle(.secondary)
            HStack(spacing: Tok.Component.Vision.hitGap) {
                Button {
                    core.toggleFavorite(id, title: header.title, coverPath: header.coverPath)
                } label: {
                    Label(header.favorited ? "取消收藏" : "收藏", systemImage: header.favorited ? "bookmark.fill" : "bookmark")
                        .visionHitTarget()
                }
                Button { oldestFirst.toggle() } label: {
                    Label(oldestFirst ? "从旧到新" : "从新到旧", systemImage: "arrow.up.arrow.down").visionHitTarget()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

struct VisionEpisodeLabel: View {
    let id: String
    let title: String
    let progress: Prog?
    let duration: Double
    var showsTime = true
    @Environment(AppCore.self) private var core
    var body: some View {
        let p = core.player!
        let current = p.current?.episodeId == id
        let live = liveProgress(
            currentId: p.current?.episodeId, position: p.position, duration: p.duration, active: p.isPlaying, episodeId: id,
            fromDb: progress)
        let state = pillState(live, knownDuration: duration)
        HStack(spacing: Tok.Component.Vision.hitGap) {
            PlaybackLoadingView(loading: current && p.loadingPlayback) {
                if current && p.looksPlaying {
                    AudioWaveformIcon(player: p)
                } else {
                    Image(systemName: state.kind == .done ? "arrow.clockwise" : "play.fill")
                }
            }
            .accessibilityHidden(true)
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            if showsTime {
                Text(state.text).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
        }

    }
}

struct VisionCourseLabel: View {
    let id: String
    let title: String
    let cover: String
    var subtitle: String? = nil
    var body: some View {
        HStack(spacing: Tok.Component.Vision.hitGap) {
            VisionArtwork(path: cover)
            VStack(alignment: .leading) {
                Text(title)
                if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
            }
            Spacer()
        }
    }
}

struct VisionArtwork: View {
    let path: String
    var large = false
    @State private var image: PlatformImage?
    @ObservedObject private var origin = OriginWatcher.shared
    var body: some View {
        Group {
            if large {
                artwork.frame(maxWidth: .infinity).aspectRatio(16 / 9, contentMode: .fit)
            } else {
                artwork.frame(width: Tok.Component.RecentRow.thumbWidth, height: Tok.Component.RecentRow.thumbHeight)
            }
        }
        .accessibilityHidden(true)
        .task(id: [path, String(large), String(origin.version)]) {
            let loaded = await ImageLoader.shared.load(path, maxPixel: large ? 640 : 320)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
    private var artwork: some View {
        Group {
            if let image {
                Image(platformImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "book.closed").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
    }
}
