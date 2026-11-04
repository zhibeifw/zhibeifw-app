import SwiftUI

/// 系列详情页。
struct SeriesView: View {
    var seriesId: String
    @Environment(AppModel.self) private var model
    @Environment(\.windowWidth) private var W
    @Environment(\.colorScheme) private var scheme
    @State private var header: SeriesHeader?
    @State private var episodes: [EpisodeRow] = []
    @State private var state: LoadState = .loading
    @State private var oldestFirst = false

    enum LoadState { case loading, ready, gone }

    var body: some View {
        PageScaffold(
            title: header?.title ?? "", largeTitle: false,
            revealAt: Layout.coverHeight(W - 2 * CP.SeriesHeader.coverMargin) + CP.SeriesHeader.titleTop + S.seriesTitle.lineHeight,
            trailing: {
                // HIG / SF Symbols：同一图标的空心 / 实心变体表示默认 / 非默认（同“邮件”的筛选按钮）
                NativeMenu(items: sortItems) {
                    Image(systemName: oldestFirst ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
                }
                .accessibilityLabel("排序")
            }
        ) {
            switch state {
            case .loading: ProgressView().frame(maxWidth: .infinity).padding(.top, Tok.Space.scale[6] * 3)
            case .gone: EmptyStateView(text: "这门课已下架", symbol: "xmark.circle").padding(.top, Tok.Space.scale[6] * 3)
            case .ready: if let h = header { content(h) }
            }
        }
        .task(id: model.catalogVersion) { load() }
        .onChange(of: [model.progressVersion, model.favoritesVersion, model.downloadsVersion]) { refreshRows() }
    }

    /// 只看本机目录，不联网（只有启动和下拉刷新取 index.json）。本机目录没有这门课 = 已下架
    private func load() {
        if let h = try? model.store.loadSeriesHeader(seriesId) {
            header = h
            refreshRows()
            state = .ready
        } else {
            state = .gone
        }
    }

    private func refreshRows() {
        episodes = (try? model.store.loadEpisodes(seriesId)) ?? []
        header?.favorited = model.store.isFavorite(seriesId)
    }

    private func sortItems() -> [[MenuItem]] {
        [
            [
                MenuItem(title: "按最新到最旧排序", icon: "arrow-down", checked: !oldestFirst) { oldestFirst = false },
                MenuItem(title: "按最旧到最新排序", icon: "arrow-up", checked: oldestFirst) { oldestFirst = true },
            ]
        ]
    }

    private func items() -> [EpisodeItem] {
        let list = episodes.map {
            EpisodeItem(
                episodeId: $0.id, seriesId: $0.seriesId, title: $0.title, progress: $0.progress, epDuration: $0.epDuration,
                dlState: $0.dlState)
        }
        return oldestFirst ? list : list.reversed()
    }

    @ViewBuilder private func content(_ h: SeriesHeader) -> some View {
        let m = Layout.pageMargin(W)
        let maxW: CGFloat = Layout.isTablet(W) ? CP.Player.tabletPortraitMaxWidth : .infinity
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                CoverImage(path: h.coverPath, colorId: h.id, radius: CP.SeriesHeader.coverRadius)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .shadow(
                        color: scheme == .dark ? .clear : .black.opacity(CP.SeriesHeader.Shadow.opacity),
                        radius: CP.SeriesHeader.Shadow.radius / 2, y: CP.SeriesHeader.Shadow.offsetY
                    )
                    .padding(.horizontal, CP.SeriesHeader.coverMargin - m)
                    .padding(.top, CP.SeriesHeader.coverTop)
                Text(h.title).zFont(S.seriesTitle).foregroundStyle(C.labelPrimary).multilineTextAlignment(.center)
                    .padding(.top, CP.SeriesHeader.titleTop)
                    .accessibilityAddTraits(.isHeader)
                buttons(h).padding(.top, CP.SeriesHeader.buttonsTop)
                if let d = h.description {
                    DescriptionBlock(text: d) { model.sheet = SheetSpec(title: h.title, category: h.categoryName, body: d) }.padding(
                        .top, CP.SeriesHeader.descTop)
                }
                infoLine(h).padding(.top, CP.SeriesHeader.infoTop)
            }
            .padding(.horizontal, m)
            Separator().padding(.horizontal, m).padding(.top, CP.SeriesHeader.separatorTop)
            HStack {
                Text("全部课程").zFont(S.sectionTitle).foregroundStyle(C.labelPrimary).accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, m)
            .padding(.top, CP.SeriesHeader.sectionTop)
            .padding(.bottom, CP.SeriesHeader.sectionBottom)
            LazyVStack(spacing: 0) {
                ForEach(items()) { e in
                    EpisodeRowView(item: e, ctx: .series(seriesId)) { it in [model.downloadItems(for: it) + [model.markItem(it)]] }
                }
            }
        }
        .frame(maxWidth: maxW)
        .frame(maxWidth: .infinity)
    }

    private func buttons(_ h: SeriesHeader) -> some View {
        let dl = seriesDownloadState()
        return HStack(spacing: CP.SeriesHeader.buttonGap) {
            pillButton(
                icon: h.favorited ? "bookmark" : "bookmark-outline", title: h.favorited ? "已收藏" : "收藏",
                label: h.favorited ? "取消收藏" : "收藏这门课"
            ) {
                model.toggleFavorite(h.id, title: h.title, coverPath: h.coverPath)
                header?.favorited.toggle()
            }
            pillButton(icon: dl.icon, ring: dl.ring, title: dl.title, label: dl.title) { tapDownloadAll(dl) }
        }
    }

    struct DlAll {
        var title: String; var icon: String; var ring: Double?; var kind: Kind
        enum Kind { case start, pause, resume, allDone }
    }

    private func seriesDownloadState() -> DlAll {
        let ids = episodes.map(\.id)
        guard !ids.isEmpty else { return DlAll(title: "下载全部", icon: "arrow-down-circle-outline", ring: nil, kind: .start) }
        var done = 0, active = 0, paused = 0
        for e in episodes {
            switch model.downloads.items[e.id]?.status ?? e.dlState {
            case .done: done += 1
            case .queued, .downloading: active += 1
            case .paused: paused += 1
            case nil: break
            }
        }
        if active > 0 { return DlAll(title: "暂停全部", icon: "", ring: Double(done) / Double(ids.count), kind: .pause) }
        if paused > 0 { return DlAll(title: "继续下载", icon: "arrow-down-circle-outline", ring: nil, kind: .resume) }
        if done == ids.count { return DlAll(title: "已全部下载", icon: "checkmark-circle", ring: nil, kind: .allDone) }
        return DlAll(title: "下载全部", icon: "arrow-down-circle-outline", ring: nil, kind: .start)
    }

    private func tapDownloadAll(_ s: DlAll) {
        guard let h = header else { return }
        switch s.kind {
        case .start:
            let todo = episodes.filter { (model.downloads.items[$0.id]?.status ?? $0.dlState) == nil }
                .map {
                    DlItem(
                        episodeId: $0.id, seriesId: h.id, seriesTitle: h.title, episodeTitle: $0.title, pos: $0.pos, audioPath: $0.audioPath
                    )
                }
            model.download(todo)
        case .pause: model.downloads.pauseAll(seriesId: h.id)
        case .resume: model.resumeDownloads(seriesId: h.id)
        case .allDone:
            model.alert = AlertSpec(
                title: "删除“\(h.title)”的下载？", message: "将删除这门课已下载的 \(episodes.count) 节内容。课程仍可在线收听，也可以重新下载。",
                buttons: [
                    AlertButton(title: "取消", role: .cancel),
                    AlertButton(title: "删除", role: .destructive) {
                        if let c = model.player.current, c.seriesId == h.id { model.player.stopIfCurrent(c.episodeId) };
                        model.downloads.removeSeries(h.id)
                    },  // 先停播放再删文件，和资料库、Android 一致,
                ])
        }
    }

    private func pillButton(icon: String, ring: Double? = nil, title: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: CP.SeriesHeader.buttonIconGap) {
                if let r = ring {
                    ProgressRing(ratio: r, paused: false, size: CP.SeriesHeader.buttonIcon)
                } else {
                    ZIcon(name: icon, size: CP.SeriesHeader.buttonIcon, color: C.labelPrimary)
                }
                Text(title).zFont(S.buttonLarge).foregroundStyle(C.labelPrimary).lineLimit(1).minimumScaleFactor(
                    Tok.Font.MinScale.buttonLarge)
            }
            .frame(maxWidth: .infinity, minHeight: CP.SeriesHeader.buttonHeight)
            .background(Capsule().fill(C.backgroundSecondary))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }

    private func infoLine(_ h: SeriesHeader) -> some View {
        HStack(spacing: 0) {
            if let cn = h.categoryName {
                Button {
                    model.nav.push(.category(h.categoryId))
                } label: {
                    HStack(spacing: Tok.Space.textGap) {
                        Text(cn).zFont(S.captionStrong).foregroundStyle(C.labelPrimary)
                        ZIcon(name: "chevron-forward", size: S.caption.size * CP.SectionTitle.inlineArrowScale, color: C.labelPrimary)
                    }
                    // 触控区补足到 44，但不撑高这一行（frame(minHeight: 44) 会把信息行上下各撑出约 14）
                    .contentShape(Rectangle().inset(by: -max(0, (Tok.Space.MinTouchTarget.ios - S.captionStrong.lineHeight) / 2)))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("\(cn)，点按查看全部课程")
            }
            // 分类名后面是一整段文字：大字号放不下时整段换行，不拆成几块各自折行
            Text(seriesInfoText(category: h.categoryName != nil, count: episodes.count, status: h.status)).zFont(S.caption).foregroundStyle(
                C.labelSecondary)
            Spacer(minLength: 0)
        }
    }
}

/// 简介：最多 3 行；超过时第 3 行末尾叠一个“更多”（左边一小段渐隐），点“更多”或简介弹出完整简介。
struct DescriptionBlock: View {
    var text: String
    var onMore: () -> Void
    @State private var truncated = false

    var body: some View {
        Button(action: onMore) {
            Text(text).zFont(S.description).foregroundStyle(C.labelSecondary).lineLimit(Int(CP.SeriesHeader.descLines))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    ViewThatFits(in: .vertical) {
                        Text(text).zFont(S.description).fixedSize(horizontal: false, vertical: true).hidden().onAppear { truncated = false }
                        Color.clear.onAppear { truncated = true }
                    }
                )
                .overlay(alignment: .bottomTrailing) {
                    if truncated {
                        HStack(spacing: 0) {
                            LinearGradient(colors: [C.background.opacity(0), C.background], startPoint: .leading, endPoint: .trailing)
                                .frame(width: CP.SeriesHeader.moreFade)
                            Text("更多").zFont(S.moreLink).foregroundStyle(C.labelPrimary).background(C.background)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!truncated)
        .accessibilityLabel(text)
        .accessibilityHint(truncated ? "点按查看完整简介" : "")
    }
}
