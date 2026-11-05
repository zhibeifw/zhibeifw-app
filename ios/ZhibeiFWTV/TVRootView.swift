import SwiftUI

/// 电视的根视图：启动、首次准备内容、出错，准备好以后是顶部标签（首页、分类、资料库、搜索、关于）。
struct TVRootView: View {
    @Environment(AppCore.self) private var core
    @Environment(TVModel.self) private var model

    var body: some View {
        @Bindable var m = model
        Group {
            switch core.phase {
            case .launching:
                // 和系统启动屏（TVInfo.plist 的 UILaunchScreen）同一个 Logo、同样大小，接上时不闪
                Image("Logo").resizable().scaledToFit().frame(width: 240).accessibilityHidden(true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(C.background.ignoresSafeArea())
            case .dbError:
                Text("读取本机数据时出错，请重新打开 App 再试；仍然不行请联系我们。")
                    .multilineTextAlignment(.center).padding(80)
            case .initializing(let attempt, let failed):
                TVInitView(attempt: attempt, failed: failed)
            case .ready:
                TVMainView()
            }
        }
        .fullScreenCover(isPresented: $m.playerOpen) { TVPlayerView() }
        .alert(
            core.alert?.title ?? "",
            isPresented: Binding(get: { core.alert != nil }, set: { if !$0 { core.alert = nil } }),
            presenting: core.alert
        ) { spec in
            ForEach(spec.buttons) { b in Button(b.title, role: b.role, action: b.action) }
        } message: { spec in
            if let msg = spec.message { Text(msg) }
        }
    }
}

/// 第一次打开：从服务器取课程目录。
private struct TVInitView: View {
    @Environment(AppCore.self) private var core
    let attempt: Int
    let failed: Bool
    @State private var refreshing = false

    var body: some View {
        VStack(spacing: 32) {
            if failed {
                Text("暂时无法连接").font(.title3)
                Button("重试") { Task { await core.runInitialization() } }
                Button(refreshing ? "正在检测…" : "刷新网络线路") {
                    guard !refreshing else { return }
                    refreshing = true
                    Task {
                        _ = await Network.shared.refreshRoutes()
                        refreshing = false
                        await core.runInitialization()
                    }
                }
            } else {
                ProgressView()
                Text("正在准备内容…")
                Text("第一次使用需要联网，请稍候").font(.callout).foregroundStyle(.secondary)
                if attempt >= 2 { Text("正在重新连接（第 \(attempt) 次）").font(.callout).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct TVMainView: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        @Bindable var m = model
        TabView(selection: $m.tab) {
            NavigationStack(path: $m.homePath) { TVHomeView().withRoutes() }
                .tabItem { Text("首页") }.tag(TVTab.home)
            NavigationStack(path: $m.categoriesPath) { TVCategoriesView().withRoutes() }
                .tabItem { Text("分类") }.tag(TVTab.categories)
            NavigationStack(path: $m.libraryPath) { TVLibraryHubView().withRoutes() }
                .tabItem { Text("资料库") }.tag(TVTab.library)
            NavigationStack(path: $m.searchPath) { TVSearchView().withRoutes() }
                .tabItem { Text("搜索") }.tag(TVTab.search)
            NavigationStack(path: $m.aboutPath) { TVAboutView().withRoutes() }
                .tabItem { Text("关于") }.tag(TVTab.about)
        }
    }
}

extension View {
    /// 各标签页面栈里能进的页面。
    func withRoutes() -> some View {
        navigationDestination(for: TVRoute.self) { r in
            switch r {
            case .series(let id): TVSeriesView(seriesId: id)
            case .category(let id): TVCategoryView(categoryId: id)
            case .recent: TVRecentView()
            case .favorites: TVFavoritesView()
            case .privacy: TVLinkView(title: "隐私政策", url: NetConfig.privacyURL)
            case .contact: TVContactView()
            case .source: TVLinkView(title: "源代码", url: NetConfig.sourceURL)
            }
        }
    }
}
