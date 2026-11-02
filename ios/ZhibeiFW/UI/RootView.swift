import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            ZStack {
                C.background.ignoresSafeArea()
                switch model.phase {
                case .launching: SplashView()
                case .dbError: DbErrorView()
                case .initializing(let n, let failed): InitView(attempt: n, failed: failed)
                case .ready: MainView()
                }
            }
            .environment(\.windowWidth, geo.size.width)
            .environment(\.windowHeight, geo.size.height)
        }
        .appAlert(model, whenPlayerOpen: false)
    }
}

/// 启动页（与 Launch Screen 一模一样，挡到本地数据准备好）。
struct SplashView: View {
    var body: some View {
        Image("Logo").resizable().scaledToFit().frame(width: CP.Splash.logoWidth).accessibilityHidden(true)
    }
}

struct DbErrorView: View {
    var body: some View {
        EmptyStateView(text: "升级本机数据时出错，你的收听记录和下载都还在。请重启 App 再试；仍然不行请联系我们。")
    }
}

/// 首次初始化：转圈 +“正在准备内容…”；失败后“暂时无法连接”+ 重试 + 刷新网络线路。
struct InitView: View {
    var attempt: Int
    var failed: Bool
    @Environment(AppModel.self) private var model
    @State private var refreshing = false

    var body: some View {
        VStack(spacing: CP.Init.spinnerGap) {
            if failed {
                Text("暂时无法连接").zFont(S.body).foregroundStyle(C.labelSecondary)
                RetryButton(title: "重试") { Task { await model.runInitialization() } }
                RetryButton(title: refreshing ? "正在检测…" : "刷新网络线路") {
                    guard !refreshing else { return }
                    refreshing = true
                    Task {
                        _ = await Network.shared.refreshRoutes()
                        refreshing = false
                        await model.runInitialization()
                    }
                }
            } else {
                ProgressView()
                VStack(spacing: CP.Init.lineGap) {
                    Text("正在准备内容…").zFont(S.body).foregroundStyle(C.labelPrimary)
                    Text("第一次使用需要联网，请稍候").zFont(S.caption).foregroundStyle(C.labelSecondary)
                    if attempt >= 2 { Text("正在重新连接（第 \(attempt) 次）").zFont(S.caption).foregroundStyle(C.labelSecondary) }
                }
            }
        }
        .padding(.horizontal, CP.EmptyState.paddingH)
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var n = model.nav
        ZStack(alignment: .bottom) {
            // 主页 / 分类 / 资料库 / 搜索：系统的标签栏。iOS 26 起是系统的液态玻璃；更早的系统是系统的模糊底
            TabView(selection: $n.tab) {
                SwiftUI.Tab("主页", systemImage: "house", value: .home) {
                    NavigationStack(path: $n.homePath) {
                        HomeView().navigationDestination(for: Route.self) { RouteView(route: $0) }
                    }
                    .nowPlayingBarBelowiOS26()
                }
                // 分类：一级页
                SwiftUI.Tab("分类", systemImage: "square.grid.2x2", value: .categories) {
                    NavigationStack(path: $n.categoriesPath) {
                        CategoriesView().navigationDestination(for: Route.self) { RouteView(route: $0) }
                    }
                    .nowPlayingBarBelowiOS26()
                }
                // 资料库：最近播放、收藏、已下载（名字照 Apple 播客、音乐）
                SwiftUI.Tab("资料库", systemImage: "square.stack", value: .library) {
                    NavigationStack(path: $n.libraryPath) {
                        LibraryHubView().navigationDestination(for: Route.self) { RouteView(route: $0) }
                    }
                    .nowPlayingBarBelowiOS26()
                }
                // 标成系统的“搜索”标签：iOS 26 单独放在右边，往下滑收起时也一直留着（和“音乐”“播客”一样）
                SwiftUI.Tab("搜索", systemImage: "magnifyingglass", value: .search, role: .search) {
                    NavigationStack(path: $n.searchPath) {
                        SearchView().navigationDestination(for: Route.self) { RouteView(route: $0) }
                    }
                    .searchOnTabiOS26(model)
                    .nowPlayingBarBelowiOS26()
                }
            }
            .searchTabActivationiOS26()
            .nowPlayingAccessoryiOS26()
            .tint(C.labelPrimary)  // 选中的标签用我们的主文字色（系统默认是蓝色，App 里别处没有蓝）

        }
        // 课程简介、全屏播放页：系统的底部弹窗
        .sheet(item: Binding(get: { model.sheet }, set: { model.sheet = $0 })) { DescriptionSheet(spec: $0) }
        .sheet(isPresented: Binding(get: { model.playerOpen && model.player.current != nil }, set: { if !$0 { model.closePlayer() } })) {
            PlayerSheet()
        }
    }

}

struct RouteView: View {
    var route: Route
    var body: some View {
        switch route {
        case .category(let id): CategoryView(categoryId: id)
        case .series(let id): SeriesView(seriesId: id)
        case .recent: RecentView()
        case .favorites: FavoritesView()
        case .library: LibraryView()
        case .libraryCourse(let id): LibraryCourseView(seriesId: id)
        case .about: AboutView()
        }
    }
}

extension View {
    /// 系统弹窗。播放页（系统 sheet）开着时，弹窗要挂在播放页上才显示得出来，所以根视图和播放页各挂一个、按状态二选一。
    func appAlert(_ model: AppModel, whenPlayerOpen: Bool) -> some View {
        alert(
            model.alert?.title ?? "",
            isPresented: Binding(get: { model.alert != nil && model.playerOpen == whenPlayerOpen }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { a in
            ForEach(a.buttons) { b in Button(b.title, role: b.role) { b.action() } }
        } message: { a in
            if let m = a.message { Text(m) }
        }
    }
}

extension View {
    /// iOS 26 起：播放胶囊放进系统标签栏上方的“底部附件”位（系统画液态玻璃，往下滑时系统把它和标签栏收成一行）。
    @ViewBuilder func nowPlayingAccessoryiOS26() -> some View {
        if #available(iOS 26.0, *) {
            self.tabViewBottomAccessory { NowPlayingAccessory() }
                .tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    /// iOS 26 以前系统没有“底部附件”：播放胶囊放在标签栏正上方，底用系统的模糊材质。
    @ViewBuilder func nowPlayingBarBelowiOS26() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            self.safeAreaInset(edge: .bottom, spacing: 0) {
                PlayerCapsule(collapsed: false)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.horizontal, Tok.Nav.sideMargin)
                    .padding(.bottom, Tok.Nav.bottomMargin)
            }
        }
    }
}

@available(iOS 26.0, *)
private struct NowPlayingAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    var body: some View {
        // 和标签栏收成一行时（inline）用紧凑样式：去掉前进 30
        PlayerCapsule(collapsed: placement == .inline)
    }
}

extension View {
    /// iOS 26：搜索框放在底部“搜索”标签上（系统 .searchable 挂在 role: .search 标签的内容上，HIG），点放大镜就直接出现搜索框和键盘。
    @ViewBuilder func searchOnTabiOS26(_ model: AppModel) -> some View {
        if #available(iOS 26.0, *) {
            @Bindable var m = model
            self.searchable(text: $m.searchQuery, prompt: "课程名")
                .onSubmit(of: .search) { model.searchSubmitted += 1 }
                // 搜索时也保留顶部“搜索”大标题（系统默认会收起）
                .searchPresentationToolbarBehavior(.avoidHidingContent)
        } else {
            self
        }
    }

    @ViewBuilder func searchTabActivationiOS26() -> some View {
        if #available(iOS 26.0, *) {
            self.tabViewSearchActivation(.searchTabSelection)
        } else {
            self
        }
    }
}
