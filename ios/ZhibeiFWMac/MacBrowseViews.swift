import SwiftUI

/// Mac 卡片尺寸（点）。窗口可以随意拉伸，网格用自适应列。
enum MacLayout {
    static let pageMargin: CGFloat = 24
    static let largeCardWidth: CGFloat = 320
    static let smallCardWidth: CGFloat = 220
    static let cardGap: CGFloat = 20
    /// 课程页整页限宽（和 iPad、Android 平板的课程页一样），窗口拉得很宽时居中
    static let seriesMaxWidth: CGFloat = 820
    static let coverRadius: CGFloat = 8
    static func coverHeight(_ w: CGFloat) -> CGFloat { (w * 9 / 16).rounded() }
    static let grid = [GridItem(.adaptive(minimum: smallCardWidth, maximum: smallCardWidth * 1.4), spacing: cardGap, alignment: .top)]
}

/// 主页：新课程、编辑精选、各分类，每行横向滚动。分类行标题可以点，进侧边栏里的这个分类。
struct MacHomeView: View {
    @Environment(AppCore.self) private var core
    @Environment(MacModel.self) private var model

    var body: some View {
        let home = core.home
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 32) {
                if model.updates.outdated && !model.updates.outdatedDismissed {
                    // 低于最低版本：和 iPhone、Android 同样的提示
                    HStack {
                        Label(
                            model.updates.channel == .site
                                ? "此版本过旧，已无法获得最新的内容更新，请到官网更新"
                                : "此版本过旧，已无法获得最新的内容更新，请到 App Store 更新",
                            systemImage: "exclamationmark.triangle")
                        Spacer()
                        Button("关闭") { model.updates.outdatedDismissed = true }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(C.backgroundSecondary))
                    .padding(.horizontal, MacLayout.pageMargin)
                }
                if core.syncFailed {
                    Text("无法更新，显示的是上一次更新的内容").font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, MacLayout.pageMargin)
                }
                if !home.ongoing.isEmpty {
                    MacCardRow(title: "新课程", cards: home.ongoing, width: MacLayout.largeCardWidth)
                }
                if !home.featured.isEmpty {
                    MacCardRow(title: "编辑精选", cards: home.featured, width: MacLayout.smallCardWidth)
                }
                ForEach(home.categories) { c in
                    MacCardRow(title: c.name, cards: c.series, width: MacLayout.smallCardWidth) {
                        model.openCategory(c.id)
                    }
                }
            }
            .padding(.vertical, MacLayout.pageMargin)
        }
        .navigationTitle("主页")
    }
}

/// 一行卡片：标题 + 横向滚动。
struct MacCardRow: View {
    let title: String
    let cards: [SeriesCard]
    let width: CGFloat
    /// 标题可以点时的动作（分类：进这个分类）
    var more: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if let more {
                    Button(action: more) {
                        HStack(spacing: 6) {
                            Text(title)
                            Image(systemName: "chevron.right").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(title)
                }
            }
            .font(.title2).fontWeight(.semibold)
            .padding(.horizontal, MacLayout.pageMargin)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: MacLayout.cardGap) {
                    ForEach(cards) { card in MacSeriesCard(card: card, width: width) }
                }
                .padding(.horizontal, MacLayout.pageMargin)
            }
            .scrollIndicators(.never)
        }
    }
}

/// 课程卡片：封面 + 课程名，点了进课程页。
struct MacSeriesCard: View {
    let card: SeriesCard
    var width: CGFloat? = nil
    /// 收藏页：右键菜单里有“取消收藏”
    var onRemoveFavorite: (() -> Void)? = nil

    var body: some View {
        NavigationLink(value: MacRoute.series(card.id)) {
            VStack(alignment: .leading, spacing: 8) {
                CoverImage(path: card.coverPath, colorId: card.id, radius: MacLayout.coverRadius)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(width: width)
                // 和 iPhone 一致：编辑精选用精选标题，新课程下面写“更新至 最后一集”
                Text(card.featureTitle ?? card.title).lineLimit(2)
                if let last = card.lastTitle {
                    Text("更新至 \(last)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onRemoveFavorite {
                Button(role: .destructive, action: onRemoveFavorite) { Label("取消收藏", systemImage: "bookmark.slash") }
            }
        }
    }
}

/// 分类：彩色方块磁贴（和 iPhone 分类页一样：分类颜色的底，图标在右上角，分类名在左下角；尺寸用同一套设计令牌），
/// 点一个进这个分类的全部课程。窗口越宽一行排得越多。鼠标移上去稍微变亮。
struct MacCategoriesView: View {
    @Environment(AppCore.self) private var core
    @State private var tiles: [CategoryTile] = []

    var body: some View {
        ScrollView(.vertical) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180, maximum: 280), spacing: Tok.Component.Tile.gap)],
                spacing: Tok.Component.Tile.gap
            ) {
                ForEach(tiles) { t in MacCategoryTile(tile: t) }
            }
            .padding(MacLayout.pageMargin)
        }
        .navigationTitle("分类")
        .task(id: core.catalogVersion) { tiles = (try? core.store.loadCategories()) ?? [] }
    }
}

private struct MacCategoryTile: View {
    let tile: CategoryTile
    @State private var hovering = false
    private typealias T = Tok.Component.Tile

    var body: some View {
        NavigationLink(value: MacRoute.category(tile.id)) {
            ZStack {
                RoundedRectangle(cornerRadius: Tok.Radius.tile, style: .continuous)
                    .fill(resolveCategoryColor(tile.color, id: tile.id).color)
                VStack {
                    HStack {
                        Spacer()
                        ZIcon(name: resolveCategoryIcon(tile.icon, id: tile.id), size: T.iconSize, color: C.onColor.opacity(T.iconOpacity))
                    }
                    Spacer()
                    HStack {
                        Text(tile.name).zFont(Tok.Font.Style.tileText).foregroundStyle(C.onColor).lineLimit(1)
                        Spacer()
                    }
                }
                .padding(T.padding)
            }
            .frame(height: T.height)
            .brightness(hovering ? 0.05 : 0)
            .contentShape(RoundedRectangle(cornerRadius: Tok.Radius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(tile.name)，查看全部课程")
    }
}

/// 一个分类的全部课程：卡片网格，滚到底再取下一页（每页 40 门，和 iPhone 一样）。
struct MacCategoryView: View {
    @Environment(AppCore.self) private var core
    let categoryId: String
    @State private var rows: [SeriesCard] = []
    @State private var done = false
    @State private var loaded = false
    private static let pageSize = 40

    var body: some View {
        ScrollView(.vertical) {
            if loaded && rows.isEmpty {
                Text("暂无课程").foregroundStyle(.secondary).padding(MacLayout.pageMargin)
            }
            LazyVGrid(columns: MacLayout.grid, alignment: .leading, spacing: 28) {
                ForEach(rows) { c in
                    MacSeriesCard(card: c).onAppear { if c.id == rows.last?.id { more() } }
                }
            }
            .padding(MacLayout.pageMargin)
        }
        .navigationTitle(core.store.categoryName(categoryId) ?? "")
        .task(id: "\(categoryId)|\(core.catalogVersion)") { reload() }
    }

    private func reload() {
        rows = (try? core.store.loadCategorySeries(categoryId, limit: Self.pageSize, offset: 0)) ?? []
        done = rows.count < Self.pageSize
        loaded = true
    }

    private func more() {
        guard !done else { return }
        let next = (try? core.store.loadCategorySeries(categoryId, limit: Self.pageSize, offset: rows.count)) ?? []
        var seen = Set(rows.map(\.id))
        rows += next.filter { seen.insert($0.id).inserted }
        if next.count < Self.pageSize { done = true }
    }
}

/// 课程页（照 iPhone 课程页和 Mac 上“播客”的节目页）：整页限宽居中。
/// 上面一块：左边封面，右边课程名、“分类 › · 共 N 节课 · 更新中”、收藏和排序、简介；下面“全部课程”，每集两行：集名，播放胶囊和“•••”。
/// 列表默认最旧的在上面（第 1 课在最上面），按一下排序按钮换成最新的在上面；只影响显示，自动接下一集始终按课程顺序。
struct MacSeriesView: View {
    @Environment(AppCore.self) private var core
    @Environment(MacModel.self) private var model
    let seriesId: String
    @State private var header: SeriesHeader?
    @State private var episodes: [EpisodeRow] = []
    @State private var loaded = false
    @State private var oldestFirst = true

    var body: some View {
        // 底下垫一层透明的：还没读到数据时上面是空的，空视图上挂的 .task 不会执行，页面会一直空白
        ZStack {
            Color.clear
            if let h = header {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 28) {
                        headerBlock(h)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("全部课程").font(.title2).fontWeight(.semibold).padding(.bottom, 4)
                            // 分隔线只画在两集之间（标题下面、最后一集下面不画），和 iPhone 课程页一样
                            let list = oldestFirst ? episodes : episodes.reversed()
                            LazyVStack(spacing: 0) {
                                ForEach(Array(list.enumerated()), id: \.element.id) { i, e in
                                    if i > 0 { Divider() }
                                    MacEpisodeRow(episode: e, ctx: .series(seriesId))
                                }
                            }
                        }
                    }
                    .frame(maxWidth: MacLayout.seriesMaxWidth)
                    .padding(MacLayout.pageMargin)
                    .frame(maxWidth: .infinity)
                }
                .navigationTitle(h.title)
            } else if loaded {
                Text("这门课已下架").foregroundStyle(.secondary)
            }
        }
        // 目录、进度、收藏变了就重读
        .task(id: "\(seriesId)|\(core.catalogVersion)|\(core.progressVersion)|\(core.favoritesVersion)") {
            header = try? core.store.loadSeriesHeader(seriesId)
            episodes = (try? core.store.loadEpisodes(seriesId)) ?? []
            loaded = true
        }
    }

    private func headerBlock(_ h: SeriesHeader) -> some View {
        HStack(alignment: .top, spacing: 24) {
            CoverImage(path: h.coverPath, colorId: h.id, radius: MacLayout.coverRadius)
                .frame(width: 300, height: MacLayout.coverHeight(300))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
            VStack(alignment: .leading, spacing: 10) {
                Text(h.title).font(.largeTitle).fontWeight(.bold).lineLimit(3)
                // “中观 › · 共 42 节课 · 更新中”：分类名可以点，进侧边栏里的这个分类（和 iPhone 一样）
                HStack(spacing: 0) {
                    if let cn = h.categoryName {
                        Button { model.openCategory(h.categoryId) } label: {
                            HStack(spacing: 2) {
                                Text(cn).fontWeight(.medium)
                                Image(systemName: "chevron.right").font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("进这个分类")
                    }
                    Text(seriesInfoText(category: h.categoryName != nil, count: episodes.count, status: h.status))
                        .foregroundStyle(.secondary)
                }
                // 收藏、排序一个逻辑：按一下就切换，按钮上显示现在的状态（和 Apple TV 一样）
                HStack(spacing: 10) {
                    Button {
                        core.toggleFavorite(h.id, title: h.title, coverPath: h.coverPath)
                    } label: {
                        Label(h.favorited ? "已收藏" : "收藏", systemImage: h.favorited ? "bookmark.fill" : "bookmark")
                    }
                    Button { oldestFirst.toggle() } label: {
                        Label(oldestFirst ? "从旧到新" : "从新到旧", systemImage: oldestFirst ? "arrow.down" : "arrow.up")
                    }
                    .accessibilityLabel(oldestFirst ? "排序：从旧到新" : "排序：从新到旧")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .padding(.top, 4)
                if let d = h.description, !d.isEmpty {
                    Text(d).foregroundStyle(.secondary).lineLimit(5).textSelection(.enabled).padding(.top, 4)
                }
            }
        }
    }
}

/// 一集（和 iPhone 课程页同样的两行）：第一行集名；第二行左边是播放胶囊（没听过“▶ 70 分钟”，听了一半带进度条“剩 32:21”，
/// 听完了打勾；在播的是暂停键），右边“•••”（标记已听完）。点整行播放 / 暂停；鼠标移上去整行浅色高亮。
struct MacEpisodeRow: View {
    @Environment(AppCore.self) private var core
    let episode: EpisodeRow
    let ctx: PlayContext
    @State private var hovering = false

    var body: some View {
        let p = core.player
        let prog = liveProgress(
            currentId: p?.current?.episodeId, position: p?.position ?? 0, duration: p?.duration ?? 0,
            active: p?.looksPlaying ?? false, episodeId: episode.id, fromDb: episode.progress)
        let playing = p?.current?.episodeId == episode.id && (p?.looksPlaying ?? false)
        let pill = pillState(prog, knownDuration: episode.epDuration ?? 0)
        VStack(alignment: .leading, spacing: 8) {
            Text(episode.title).font(.headline).lineLimit(2)
            HStack {
                Button { core.togglePlay(episode.id, ctx: ctx) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: playing ? "pause.fill" : (pill.kind == .done ? "checkmark" : "play.fill"))
                            .font(.caption)
                        if pill.kind == .half, let prog {
                            ProgressView(value: progressRatio(prog.position, prog.duration)).frame(width: 36)
                        }
                        Text(pill.text).monospacedDigit()
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityLabel((playing ? "暂停 " : "播放 ") + episode.title)
                Spacer()
                Menu {
                    MarkCompletedButton(episodeId: episode.id, seriesId: episode.seriesId, completed: prog?.completed ?? false)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("更多操作")
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.primary.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { core.togglePlay(episode.id, ctx: ctx) }
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

/// 最近播放：点一集接着播；右键：标记已听完、前往课程、删除记录。工具栏里有“清空”。
struct MacRecentView: View {
    @Environment(AppCore.self) private var core
    @Environment(MacModel.self) private var model
    @State private var rows: [RecentRow] = []

    var body: some View {
        Group {
            if rows.isEmpty {
                Text("暂无收听记录").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 和课程页一样：整页限宽居中，“N 条记录”下面不画线，分隔线只画在两条记录之间
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(rows.count) 条记录").foregroundStyle(.secondary)
                        LazyVStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                                if i > 0 { Divider() }
                                row(r)
                            }
                        }
                    }
                    .frame(maxWidth: MacLayout.seriesMaxWidth)
                    .padding(MacLayout.pageMargin)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("最近播放")
        .toolbar {
            ToolbarItem {
                Button(role: .destructive, action: confirmClear) { Label("清空", systemImage: "trash") }
                    .disabled(rows.isEmpty)
                    .help("清空最近列表")
            }
        }
        .task(id: "\(core.catalogVersion)|\(core.progressVersion)") {
            rows = (try? core.store.loadRecent(limit: 200)) ?? []
        }
    }

    private func row(_ r: RecentRow) -> some View {
        let p = core.player
        let prog = liveProgress(
            currentId: p?.current?.episodeId, position: p?.position ?? 0, duration: p?.duration ?? 0,
            active: p?.looksPlaying ?? false, episodeId: r.episodeId, fromDb: r.progress)
        return Button {
            core.playFromRecent(r, open: false)
        } label: {
            HStack(spacing: 14) {
                CoverImage(path: r.coverPath, colorId: r.seriesId, radius: 6)
                    .frame(width: 96, height: MacLayout.coverHeight(96))
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.epTitle).lineLimit(2)
                    Text(r.seriesTitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(r.gone ? "已下架" : progressText(prog, knownDuration: r.epDuration))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            MarkCompletedButton(episodeId: r.episodeId, seriesId: r.seriesId, completed: prog?.completed ?? false)
            Button { model.goToSeries(r.seriesId) } label: { Label("前往课程", systemImage: "arrow.forward.circle") }
            Divider()
            Button(role: .destructive) { core.hideRecent(r.episodeId) } label: { Label("删除记录", systemImage: "trash") }
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

/// 收藏：卡片网格，点一门课进课程页；右键：取消收藏。
struct MacFavoritesView: View {
    @Environment(AppCore.self) private var core
    @State private var rows: [FavoriteRow] = []

    var body: some View {
        Group {
            if rows.isEmpty {
                Text("还没有收藏的课程").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVGrid(columns: MacLayout.grid, alignment: .leading, spacing: 28) {
                        ForEach(rows) { f in
                            MacSeriesCard(
                                card: SeriesCard(id: f.id, title: f.title, coverPath: f.coverPath, status: f.status ?? ""),
                                onRemoveFavorite: { core.removeFavorite(f.id) })
                        }
                    }
                    .padding(MacLayout.pageMargin)
                }
            }
        }
        .navigationTitle("收藏")
        .task(id: "\(core.catalogVersion)|\(core.favoritesVersion)") {
            rows = (try? core.store.loadFavorites()) ?? []
        }
    }
}

/// 搜索结果：按课程名搜，和 iPhone 同一套查询。停止输入 0.3 秒就搜。
struct MacSearchView: View {
    @Environment(AppCore.self) private var core
    let query: String
    @State private var result: Store.SearchResult?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                if let r = result {
                    if r.rows.isEmpty {
                        Text("未找到相关内容").foregroundStyle(.secondary)
                    } else {
                        if r.fallback {
                            Text("已显示“\(r.matched)”的结果").font(.callout).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: MacLayout.grid, alignment: .leading, spacing: 28) {
                            ForEach(r.rows) { c in MacSeriesCard(card: c) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MacLayout.pageMargin)
        }
        .navigationTitle("搜索")
        // 输入停一下再搜；又输入了就取消上一次（task(id:) 换 id 时会取消旧任务）
        .task(id: query) {
            let q = query
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let store = core.store!
            // 搜不到整句时会从开头逐字加长多查几次，放到后台，不卡输入
            let r = await Task.detached(priority: .userInitiated) { try? store.searchSeries(q) }.value
            guard !Task.isCancelled else { return }
            result = r
        }
    }
}
