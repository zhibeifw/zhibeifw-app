import SwiftUI

/// Mac 的根视图：启动、首次准备内容、出错；准备好以后是系统的侧边栏布局（左边侧边栏，右边内容），
/// 工具栏中间是播放控制。和 Mac 上的“播客”“音乐”一样，全部用系统组件。播放页打开时铺满整个窗口（和 iPhone、Apple TV 一样）。
struct MacRootView: View {
    @Environment(AppCore.self) private var core

    var body: some View {
        Group {
            switch core.phase {
            case .launching:
                Image("Logo").resizable().scaledToFit().frame(width: 160).accessibilityHidden(true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .dbError:
                Text("读取本机数据时出错，请重新打开 App 再试；仍然不行请联系我们。")
                    .multilineTextAlignment(.center).padding(60)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .initializing(let attempt, let failed):
                MacInitView(attempt: attempt, failed: failed)
            case .ready:
                MacMainView()
            }
        }
        .frame(minWidth: 820, minHeight: 540)
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
private struct MacInitView: View {
    @Environment(AppCore.self) private var core
    let attempt: Int
    let failed: Bool
    @State private var refreshing = false

    var body: some View {
        VStack(spacing: 16) {
            if failed {
                Text("暂时无法连接").font(.title3)
                HStack {
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
                }
            } else {
                ProgressView()
                Text("正在准备内容…")
                Text("第一次使用需要联网，请稍候").font(.callout).foregroundStyle(.secondary)
                if attempt >= 2 { Text("正在重新连接（第 \(attempt) 次）").font(.callout).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MacMainView: View {
    @Environment(AppCore.self) private var core
    @Environment(MacModel.self) private var model

    var body: some View {
        @Bindable var m = model
        ZStack {
        NavigationSplitView {
            // 侧边栏：主页、分类；资料库：最近播放、收藏。分类只放一个入口（14 个分类全列出来太长）
            List(selection: $m.section) {
                Label("主页", systemImage: "house").tag(MacSection.home)
                Label("分类", systemImage: "square.grid.2x2").tag(MacSection.categories)
                Section("资料库") {
                    Label("最近播放", systemImage: "clock").tag(MacSection.recent)
                    Label("收藏", systemImage: "bookmark").tag(MacSection.favorites)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            NavigationStack(path: $m.path) {
                Group {
                    // 搜索框里有字时内容区显示搜索结果（和 Mac 上的“音乐”一样），清空后回到侧边栏选中的那一项
                    if !normalizeText(model.query).isEmpty {
                        MacSearchView(query: model.query)
                    } else {
                        switch model.section ?? .home {
                        case .home: MacHomeView()
                        case .categories: MacCategoriesView()
                        case .recent: MacRecentView()
                        case .favorites: MacFavoritesView()
                        }
                    }
                }
                .navigationDestination(for: MacRoute.self) { r in
                    switch r {
                    case .series(let id): MacSeriesView(seriesId: id)
                    case .category(let id): MacCategoryView(categoryId: id)
                    }
                }
            }
        }
        .searchable(text: $m.query, placement: .sidebar, prompt: "课程名或拼音首字母")
        .onChange(of: model.query) { _, v in
            if v.count > MAX_QUERY_LENGTH { model.query = String(v.prefix(MAX_QUERY_LENGTH)) }
            // 打字时回到搜索结果；清空时不动（“前往课程”“进分类”会先清空搜索词，再进页面）
            if !v.isEmpty { model.path = [] }
        }
        .toolbar {
            ToolbarItem(placement: .principal) { MacNowPlayingBar() }
        }
            // 播放页：从下往上铺满窗口，盖住侧边栏和内容区；收起后回到原来的页面，声音照常播
            if model.playerOpen {
                MacPlayerView()
                    .transition(.move(edge: .bottom))
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.playerOpen)
        // 播放页打开时藏起整个工具栏，播放页占满窗口；关闭用播放页左上角的圈 X（或 Esc）
        .toolbar(model.playerOpen ? .hidden : .visible, for: .windowToolbar)
    }
}
