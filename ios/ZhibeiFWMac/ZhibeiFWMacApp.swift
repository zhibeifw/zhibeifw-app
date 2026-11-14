import SwiftUI
import Observation

/// Mac 版入口。共用的状态与动作在 AppCore（ios/Shared/App）；Mac 自己的界面状态在 MacModel。
/// 只有一个主窗口（和 Mac 上的“播客”“音乐”一样），另有“关于智悲佛网”窗口；菜单栏多一个“控制”菜单。
@main
struct ZhibeiFWMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    private let model = MacModel.shared

    var body: some Scene {
        Window("智悲佛网", id: "main") {
            MacRootView()
                .environment(model)
                .environment(model.core)
                .task {
                    await model.core.boot()
                    await model.updates.check(manual: false)
                }
                // 点桌面 / 通知中心的小组件打开 App
                .onOpenURL { model.openWidgetLink($0) }
                // Mac 上窗口开着时切到别的 App，场景不算“退到后台”：改看 App 是否是当前 App。
                // 切回来时取一次 iCloud 改动、按时检查目录和更新；切走时存播放位置、把没传的改动传上去
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.core.onForeground()
                    Task { await model.updates.check(manual: false) }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    model.core.onBackground()
                    Task { await model.widgets.writeNow() }
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands { MacCommands(model: model) }

        Window("关于智悲佛网", id: "about") {
            MacAboutView()
                .environment(model.core)
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MacModel.shared.widgets.quickUpdateNowPlaying(playing: false)
    }
}

/// 侧边栏的一项：主页、分类、最近播放、收藏（分类只有一个入口，点进去是分类磁贴，和 iPhone、Apple TV 一样）。
enum MacSection: Hashable {
    case home, categories, recent, favorites
}

/// 内容区页面栈里能进的页面。
enum MacRoute: Hashable {
    case series(String)
    case category(String)
}

/// Mac 版的 App 模型：AppCore 加上 Mac 自己的界面状态（侧边栏选中项、页面栈与搜索词）。
@MainActor
@Observable
final class MacModel {
    static let shared = MacModel()

    @ObservationIgnored let core: AppCore
    /// 检查更新（官网版提示新版本，App Store 版只提示过旧）
    let updates = MacUpdateChecker()
    /// 桌面 / 通知中心小组件的数据（和 iPhone 共用 WidgetFeeder）
    @ObservationIgnored private(set) var widgets: WidgetFeeder!
    /// 冷启动时点小组件带来的链接：等进了主页再打开
    @ObservationIgnored private var pendingLink: URL?
    /// App 开着时每 2 小时左右取一次目录、更新小组件（苹果的 NSBackgroundActivityScheduler，系统挑空闲的时候做）。
    /// App 没开着时靠小组件自己取（WidgetCatalog）
    @ObservationIgnored private let refresher = NSBackgroundActivityScheduler(identifier: "com.zhibeifw.app.refresh")
    var section: MacSection? = .home {
        didSet { if section != oldValue { path = [] } }
    }
    var path: [MacRoute] = []
    /// 侧边栏开着还是收起：放在模型里，打开、关掉播放页时保持原样
    var columns: NavigationSplitViewVisibility = .all
    var query = ""

    /// 进一个分类的全部课程（主页分类行的标题、课程页的分类名）：切到侧边栏的“分类”，再进这个分类。
    func openCategory(_ categoryId: String) {
        query = ""
        section = .categories
        path = [.category(categoryId)]
    }

    /// “前往课程”：在当前内容区里进这门课；最上面已经是这门课就不再进一层。
    func goToSeries(_ seriesId: String) {
        query = ""
        let r = MacRoute.series(seriesId)
        if path.last != r { path.append(r) }
    }

    private init() {
        core = AppCore()
        // 选集在底部播放栏播放，保留当前浏览页面。
        core.presentPlayer = nil
        widgets = WidgetFeeder(core: core)
        core.onReady = { [weak self] in
            guard let self else { return }
            self.widgets.start()
            if let u = self.pendingLink { self.pendingLink = nil; self.openWidgetLink(u) }
            self.startRefresher()
        }
        core.prefetchHomeCovers = { home in
            let cards = home.ongoing + home.featured + home.categories.flatMap { $0.series.prefix(6) }
            ImageLoader.shared.prefetch(cards.map { (path: $0.coverPath, requested: COVER_THUMB_WIDTHS.last!) })
        }
    }
}

extension MacModel {
    /// 小组件在后台启动时也使用主 App 的播放器。
    func togglePlaybackFromWidget(_ id: String) async {
        guard await readyForWidget(), let p = core.player else { return }
        let on = p.current?.episodeId != id || !p.looksPlaying
        if p.current?.episodeId == id {
            if on && !p.looksPlaying { p.resume() }
            if !on && p.looksPlaying { p.pause() }
        } else if on {
            p.start(id, ctx: .single)
        }
        widgets.quickUpdateNowPlaying(playing: on)
        guard on else { return }
        for _ in 0..<100 where !p.isPlaying && p.error == nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if !p.isPlaying { widgets.quickUpdateNowPlaying(playing: false) }
    }

    fileprivate func startRefresher() {
        refresher.repeats = true
        refresher.interval = 2 * 3600
        refresher.tolerance = 30 * 60
        refresher.qualityOfService = .utility
        refresher.schedule { [weak self] done in
            Task { @MainActor in
                if let self {
                    WidgetLog.note("后台刷新：取目录")
                    await self.core.syncCatalog(userInitiated: false)
                    await self.widgets.writeNow()
                }
                done(.finished)
            }
        }
    }

    /// 启动只做一次：窗口那边已经在启动时，这里的 boot() 直接返回，要等它做完（最多约 10 秒）
    private func readyForWidget() async -> Bool {
        await core.boot()
        for _ in 0..<100 where core.phase == .launching {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return core.phase == .ready
    }

    /// 点小组件内容进入对应课程页。
    func openWidgetLink(_ url: URL) {
        guard let link = WidgetLink(url) else { return }
        guard core.phase == .ready else { pendingLink = url; return }
        switch link {
        case .player(let seriesId):
            openWidgetLink(WidgetLink.series(seriesId).url)
        case .series(let id):
            // 一律回到侧边栏的主页、只留这门课一页（和 iPhone 一样）
            query = ""
            section = .home
            path = [.series(id)]
        }
    }
}

/// 菜单栏：“关于智悲佛网”放在 App 菜单的第一项（系统默认位置）；“控制”菜单放播放相关的命令和快捷键。
struct MacCommands: Commands {
    let model: MacModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于智悲佛网", systemImage: "info.circle") { openWindow(id: "about") }
        }
        // 只有一个主窗口：去掉“新建窗口”
        CommandGroup(replacing: .newItem) {}
        CommandMenu("控制") {
            MacControlMenu(model: model)
        }
    }
}

/// “控制”菜单的内容。没有在播的一集时都不可用。
private struct MacControlMenu: View {
    let model: MacModel
    private var p: PlayerController? { model.core.player }

    var body: some View {
        let has = p?.current != nil
        Button(p?.looksPlaying == true ? "暂停" : "播放", systemImage: p?.looksPlaying == true ? "pause.fill" : "play.fill") { p?.toggle() }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!has)
        Button("后退 \(Int(SEEK_BACK_SECONDS)) 秒", systemImage: "gobackward.\(Int(SEEK_BACK_SECONDS))") { p?.seek(by: -SEEK_BACK_SECONDS) }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(!has)
        Button("前进 \(Int(SEEK_FORWARD_SECONDS)) 秒", systemImage: "goforward.\(Int(SEEK_FORWARD_SECONDS))") {
            p?.seek(by: SEEK_FORWARD_SECONDS)
        }
        .keyboardShortcut(.rightArrow, modifiers: .command)
        .disabled(!has)
        Divider()
        Menu("播放速度", systemImage: "speedometer") {
            ForEach(PLAYBACK_RATES, id: \.self) { r in
                Toggle(rateMenuTitle(r), isOn: Binding(get: { p?.rate == r }, set: { _ in p?.setRate(r) }))
            }
        }
        .disabled(!has)
        Menu("睡眠定时", systemImage: "moon") {
            ForEach(SLEEP_CHOICES) { ch in
                Toggle(ch.title, isOn: Binding(get: { p?.sleep.choiceId == ch.id }, set: { _ in p?.setSleep(sleepSetting(ch)) }))
            }
        }
        .disabled(!has)
        Divider()
        Button("前往正在播放的课程", systemImage: "arrow.forward.circle") {
            if let current = p?.current { model.goToSeries(current.seriesId) }
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .disabled(!has)
    }
}
