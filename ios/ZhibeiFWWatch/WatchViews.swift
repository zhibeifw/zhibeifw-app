import SwiftUI

enum WatchRoute: Hashable {
    case home, categories, library, recent, favorites, downloads, search, settings, privacy, source, contact
    case category(String, String), series(String), seriesDownloads(String)
    case episode(String, String, String, WatchPlayScope)
}

enum WatchPlayScope: Hashable {
    case series, recent, downloads
    func context(_ series: String) -> PlayContext {
        switch self {
        case .series: .series(series)
        case .recent: .single
        case .downloads: .library(series)
        }
    }
}

struct WatchRootView: View {
    @Environment(WatchModel.self) private var model
    @Environment(AppCore.self) private var core
    @State private var continuation: RecentRow?

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            Group {
                switch core.phase {
                case .ready: menu
                case .dbError:
                    ContentUnavailableView("无法打开资料库", systemImage: "exclamationmark.triangle")
                case .initializing(_, true):
                    VStack {
                        Text("暂时无法连接")
                        Button("重试") { Task { await core.runInitialization() } }
                    }
                default: ProgressView("载入课程")
                }
            }
            .navigationTitle("智悲佛网")
            .navigationDestination(for: WatchRoute.self) { route in
                switch route {
                case .home: WatchHomeView()
                case .categories: WatchCategoriesView()
                case .category(let id, let title): WatchCategoryView(id: id, title: title)
                case .series(let id): WatchSeriesView(id: id)
                case .library: WatchLibraryHubView()
                case .recent: WatchRecentView()
                case .favorites: WatchFavoritesView()
                case .downloads: WatchDownloadLibraryView()
                case .seriesDownloads(let id): WatchSeriesDownloadsView(series: id, downloadedOnly: true)
                case .search: WatchSearchView()
                case .settings: WatchSettingsView()
                case .contact: WatchContactView()
                case .privacy: WatchPrivacyView()
                case .source: WatchSourceView()
                case .episode(let id, let series, let title, let scope):
                    WatchEpisodeActionsView(id: id, series: series, title: title, scope: scope)
                }
            }
        }
        .sheet(isPresented: $model.playerOpen) {
            NavigationStack { WatchPlayerView() }
                .modifier(WatchAlertPresenter(player: true))
        }
        .modifier(WatchAlertPresenter(player: false))
    }

    private var menu: some View {
        List {
            NavigationLink(value: WatchRoute.home) { Label("主页", systemImage: "house") }
            NavigationLink(value: WatchRoute.categories) { Label("分类", systemImage: "square.grid.2x2") }
            NavigationLink(value: WatchRoute.library) { Label("资料库", systemImage: "books.vertical") }
            NavigationLink(value: WatchRoute.search) { Label("搜索", systemImage: "magnifyingglass") }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(value: WatchRoute.settings) { Image(systemName: "gearshape") }
                    .accessibilityLabel("设置与关于")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if core.player.current != nil {
                        model.playerOpen = true
                    } else if let continuation {
                        core.playFromRecent(continuation, open: true)
                    }
                } label: {
                    Image(systemName: "waveform")
                }
                .accessibilityLabel("正在播放")
                .disabled(core.player.current == nil && continuation == nil)
            }
        }
        .task(id: model.versions) {
            continuation = ((try? core.store.loadRecent()) ?? []).first(where: { !$0.progress.completed })
        }
    }

}

struct WatchAlertPresenter: ViewModifier {
    let player: Bool
    @Environment(WatchModel.self) private var model
    @Environment(AppCore.self) private var core
    func body(content: Content) -> some View {
        content.alert(
            core.alert?.title ?? "",
            isPresented: Binding(
                get: { core.alert != nil && model.playerOpen == player },
                set: { if !$0 && model.playerOpen == player { core.alert = nil } }
            ), presenting: core.alert
        ) { spec in
            ForEach(spec.buttons) { button in
                Button(button.title, role: button.role) {
                    core.alert = nil
                    button.action()
                }
            }
        } message: { spec in
            if let message = spec.message { Text(message) }
        }
    }
}

struct WatchCourseLabel: View {
    let title: String
    let cover: String
    let id: String
    var subtitle: String? = nil
    @Environment(AppCore.self) private var core
    var body: some View {
        VStack(alignment: .leading) {
            WatchArtwork(path: cover, id: id)
                .aspectRatio(16 / 9, contentMode: .fit)
            Text(title).font(.headline)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct WatchEpisodeLabel: View {
    let id: String
    let title: String
    let progress: Prog?
    var duration: Double = 0
    var subtitle: String? = nil
    var compactPlayback = false
    @Environment(AppCore.self) private var core
    var body: some View {
        let p = core.player!
        let live = liveProgress(
            currentId: p.current?.episodeId, position: p.position, duration: p.duration,
            active: p.isPlaying, episodeId: id, fromDb: progress)
        let state = pillState(live, knownDuration: duration)
        VStack(alignment: .leading) {
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            Text(title).font(.headline)
            HStack {
                Group {
                    if p.current?.episodeId == id && p.loadingPlayback {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel("正在加载")
                    } else {
                        Image(
                            systemName: p.current?.episodeId == id && p.looksPlaying
                                ? (compactPlayback ? "pause.circle" : "waveform")
                                : (state.kind == .done ? (compactPlayback ? "arrow.clockwise" : "checkmark.circle") : "play.circle"))
                    }
                }
                .frame(
                    width: compactPlayback ? Tok.Component.EpisodeRow.statusIcon : nil,
                    height: compactPlayback ? Tok.Component.EpisodeRow.statusIcon : nil)
                Text(state.text).monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                p.current?.episodeId == id && p.looksPlaying
                    ? "暂停，\(state.text)"
                    : state.kind == .done && compactPlayback ? "已听完，点按重新播放，\(state.text)" : state.text)
            if !compactPlayback, let live, live.duration > 0, !live.completed {
                ProgressView(value: progressRatio(live.position, live.duration))
            }
        }
    }
}

struct WatchEpisodeRow: View {
    let id: String
    let series: String
    let title: String
    let scope: WatchPlayScope
    let progress: Prog?
    var duration: Double = 0
    var subtitle: String? = nil
    var play: (() -> Void)? = nil
    var compactPlayback = false
    @Environment(AppCore.self) private var core
    @Environment(WatchModel.self) private var model
    var body: some View {
        Button {
            if let play {
                play()
            } else if compactPlayback {
                core.togglePlay(id, ctx: scope.context(series))
            } else {
                core.playAndOpen(id, ctx: scope.context(series))
            }
        } label: {
            HStack(alignment: .bottom) {
                WatchEpisodeLabel(
                    id: id, title: title, progress: progress, duration: duration, subtitle: subtitle, compactPlayback: compactPlayback
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                WatchEpisodeDownloadIndicator(id: id)
            }
            .contentShape(Rectangle())
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if compactPlayback && scope == .series {
                Button {
                    core.markCompleted(id, seriesId: series, completed: progress?.completed != true)
                } label: {
                    Label(
                        progress?.completed == true ? "标记为未听完" : "标记为已听完",
                        systemImage: progress?.completed == true ? "arrow.uturn.backward" : "checkmark")
                }.tint(.gray)
                let downloaded = (model.downloads?.items[id]?.status ?? core.store.getDownload(id)?.state) == .done
                Button(role: downloaded ? .destructive : nil) {
                    if downloaded {
                        model.confirm("删除此下载？") { model.deleteDownloads([id]) }
                    } else {
                        model.download(Set([id]))
                    }
                } label: {
                    Label(downloaded ? "删除下载" : "下载", systemImage: downloaded ? "trash" : "arrow.down")
                }.tint(downloaded ? .red : .gray)
            } else if scope == .recent {
                Button {
                    model.showSeries(series)
                } label: {
                    Label("前往课程", systemImage: "arrow.right")
                }.tint(.gray)
                Button {
                    core.hideRecent(id)
                } label: {
                    Label("移除记录", systemImage: "xmark")
                }.tint(.gray)
            } else {
                Button {
                    model.path.append(.episode(id, series, title, scope))
                } label: {
                    Label("更多", systemImage: "ellipsis")
                }
            }
        }
    }
}

struct WatchEpisodeDownloadIndicator: View {
    let id: String
    @Environment(AppCore.self) private var core
    @Environment(WatchModel.self) private var model

    var body: some View {
        let _ = model.downloadVersion
        let status = model.downloads?.items[id]?.status ?? core.store.getDownload(id)?.state
        switch status {
        case .done:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel("已下载")
        case .queued, .downloading, .paused:
            let paused = status == .paused
            Button {
                if paused {
                    model.download(Set([id]))
                } else {
                    model.downloads?.pause(id)
                }
            } label: {
                Gauge(value: max(Tok.Component.EpisodeRow.ringMinArc, model.downloads?.ratio(id) ?? 0)) {
                    EmptyView()
                } currentValueLabel: {
                    Image(systemName: paused ? "pause.fill" : "stop.fill")
                        .font(.title2)
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(paused ? .secondary : .primary)
                .frame(width: Tok.Component.EpisodeRow.gaugeNative, height: Tok.Component.EpisodeRow.gaugeNative)
                .scaleEffect(Tok.Component.EpisodeRow.ring / Tok.Component.EpisodeRow.gaugeNative)
                .frame(width: Tok.Component.EpisodeRow.ring, height: Tok.Component.EpisodeRow.ring)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(paused ? "已暂停，点按继续下载" : "下载中，点按暂停")
        case nil:
            EmptyView()
        }
    }
}

/// 封面只使用系统 Image 展示，离线文件与缓存沿用共用数据层。
struct WatchArtwork: View {
    let path: String
    let id: String
    @Environment(AppCore.self) private var core
    @State private var image: PlatformImage?
    var body: some View {
        Group {
            if let image {
                Image(platformImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "book.closed").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
        .task(id: [path, id]) {
            let file = core.files.coverFile(seriesId: id)
            let loaded = await ImageLoader.shared.load(
                path.isEmpty ? "local:" + id : path,
                maxPixel: COVER_THUMB_WIDTHS.first!, localFile: file)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
