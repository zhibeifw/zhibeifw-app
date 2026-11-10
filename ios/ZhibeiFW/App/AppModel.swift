import SwiftUI
import Observation

/// iPhone / iPad 版的 App 模型。页面只读它、调它，不各自保存一份播放或下载状态。
/// 两端共用的部分（数据库、目录同步、播放入口、进度和收藏）在 AppCore（ios/Shared/App），这里转一层，页面照旧用 model.xxx；
/// 这里自己管的是 iPhone 才有的：下载、另存封面、检查更新、导航、播放页、简介弹窗、搜索框。
@MainActor
@Observable
final class AppModel {
    @ObservationIgnored let core: AppCore
    private(set) var downloads: DownloadManager!
    /// 下载状态（排队、下载中、暂停、已下载、删除）
    var downloadsVersion = 0

    @ObservationIgnored let nav = Navigator()
    @ObservationIgnored let upgrade = UpgradeChecker()
    @ObservationIgnored private(set) var widgets: WidgetFeeder!
    /// 冷启动时点小组件带来的链接：等进了主页再打开
    @ObservationIgnored private var pendingLink: URL?
    private var covers: CoverArchive { CoverArchive(files: files) }
    var playerOpen = false
    var sheet: SheetSpec?
    /// 搜索框的文字（iOS 26 搜索框在底部“搜索”标签上，由根视图持有；按键盘“搜索”时 searchSubmitted 加一）
    var searchQuery = ""
    var searchSubmitted = 0

    init() {
        core = AppCore()
        core.onStoreReady = { [weak self] in await self?.setUpDownloads() }
        core.onReady = { [weak self] in
            guard let self else { return }
            self.widgets.start()
            WidgetLog.note("进入主页，等着的链接=\(self.pendingLink?.absoluteString ?? "无")")
            if let u = self.pendingLink { self.pendingLink = nil; self.openWidgetLink(u) }
            if let a = QuickAction.pending ?? self.pendingQuickAction {
                QuickAction.pending = nil; self.pendingQuickAction = nil; self.openQuickAction(a)
            }
            Task { await self.upgrade.check(manual: false) }
        }
        core.prefetchHomeCovers = { home in Self.prefetchHomeCovers(home) }
        core.presentPlayer = { [weak self] in self?.openPlayer() }
        widgets = WidgetFeeder(core: core)
        QuickAction.handler = { [weak self] a in self?.openQuickAction(a) }
        // 后台刷新：系统在后台叫醒 App 时取一次目录（和切回前台时一样按 2 小时一次判断），有新课就更新小组件
        BackgroundRefresh.handler = { [weak self] in
            guard let self, await self.readyForWidget() else { return }
            WidgetLog.note("后台刷新：取目录")
            await self.core.syncCatalog(userInitiated: false)
            await self.widgets.writeNow()
        }
        connectWidgetButtons()
    }

    // MARK: 小组件

    /// 小组件上的播放按钮（系统在 App 的进程里执行；App 没开着时在后台启动，这时界面还没起来，要自己先启动）
    private func connectWidgetButtons() {
        // 打开：播这一集（不是当前这一集就换成它）；关上：暂停当前这一集
        WidgetBridge.setPlaying = { [weak self] id, on in
            WidgetLog.note("按钮：\(id) play=\(on)")
            guard let self, await self.readyForWidget() else { WidgetLog.note("按钮：App 没准备好"); return }
            if self.player.current?.episodeId == id {
                if on && !self.player.looksPlaying { self.player.resume() }
                if !on && self.player.looksPlaying { self.player.pause() }
            } else if on {
                self.player.start(id, ctx: .single)
            }
            // 先按要切到的状态写，按钮马上变
            self.widgets.quickUpdateNowPlaying(playing: on)
            // 播放：等声音真的出来（或出错、最多 10 秒）再结束这个动作。苹果对音频动作的要求：动作结束前要开始出声，
            // 否则 App 在后台被叫起来时，动作一结束就被挂起，播放起不来（小组件上又变回播放键）
            guard on else { return }
            for _ in 0..<100 where !self.player.isPlaying && self.player.error == nil {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            WidgetLog.note("按钮：出声=\(self.player.isPlaying) 出错=\(self.player.error != nil)")
            if !self.player.isPlaying { self.widgets.quickUpdateNowPlaying(playing: false) }
        }
    }

    /// 启动只做一次：界面那边已经在启动时，这里的 boot() 直接返回，要等它做完（最多约 10 秒）
    private func readyForWidget() async -> Bool {
        await boot()
        for _ in 0..<100 where phase == .launching {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return phase == .ready
    }

    /// 冷启动时长按图标菜单带来的：等进了主页再打开
    @ObservationIgnored private var pendingQuickAction: QuickAction?

    /// 长按 App 图标菜单：切到资料库标签，只留对应的那一页（之前停在哪都一样）
    func openQuickAction(_ a: QuickAction) {
        guard phase == .ready else { pendingQuickAction = a; return }
        closePlayer()
        nav.tab = .library
        switch a {
        case .recent: nav.libraryPath = [.recent]
        case .favorites: nav.libraryPath = [.favorites]
        case .downloads: nav.libraryPath = [.library]
        }
    }

    /// 点小组件打开 App：进课程页，或打开播放页（App 里已经不是这一集了就进课程页）
    func openWidgetLink(_ url: URL) {
        WidgetLog.note("打开链接：\(url.absoluteString) phase=\(phase)")
        guard let link = WidgetLink(url) else { WidgetLog.note("链接解析失败"); return }
        guard phase == .ready else { pendingLink = url; return }
        switch link {
        case .player(let seriesId):
            // App 被系统关过、已经不是这一集了：进这门课
            if player.current != nil { openPlayer() } else { openWidgetLink(WidgetLink.series(seriesId).url) }
        case .series(let id):
            closePlayer()
            // 一律切到主页标签、只留这门课一页：App 之前停在别的标签、别的页面上时，推进那一栏会看不到
            WidgetLog.note("进课程页：\(id)（原来在 \(nav.tab)）")
            nav.tab = .home
            nav.homePath = [.series(id)]
        }
    }

    // MARK: 共用部分（AppCore）

    var files: AppFiles { core.files }
    var store: Store! { core.store }
    var player: PlayerController! { core.player }
    var phase: Phase { core.phase }
    var home: HomeData { core.home }
    var syncFailed: Bool { core.syncFailed }
    var autoUpdating: Bool { core.autoUpdating }
    var progressVersion: Int { core.progressVersion }
    var favoritesVersion: Int { core.favoritesVersion }
    var catalogVersion: Int { core.catalogVersion }
    var alert: AlertSpec? {
        get { core.alert }
        set { core.alert = newValue }
    }

    func boot() async { await core.boot() }
    func runInitialization() async { await core.runInitialization() }
    func loadHome() { core.loadHome() }
    @discardableResult
    func syncCatalog(userInitiated: Bool) async -> SyncSummary? { await core.syncCatalog(userInitiated: userInitiated) }
    func playAndOpen(_ episodeId: String, ctx: PlayContext) { core.playAndOpen(episodeId, ctx: ctx) }
    func togglePlay(_ episodeId: String, ctx: PlayContext) { core.togglePlay(episodeId, ctx: ctx) }
    func playFromRecent(_ row: RecentRow, open: Bool) { core.playFromRecent(row, open: open) }
    func markCompleted(_ episodeId: String, seriesId: String, completed: Bool) {
        core.markCompleted(episodeId, seriesId: seriesId, completed: completed)
    }
    func hideRecent(_ episodeId: String) { core.hideRecent(episodeId) }
    func clearRecent() { core.clearRecent() }
    func toggleFavorite(_ seriesId: String, title: String, coverPath: String) {
        core.toggleFavorite(seriesId, title: title, coverPath: coverPath)
    }
    func removeFavorite(_ seriesId: String) { core.removeFavorite(seriesId) }
    func refreshRoutes() async -> String { await core.refreshRoutes() }

    // MARK: 启动、前后台

    /// 数据库和播放器准备好之后（读主页之前）：建下载管理，和系统后台下载对账。
    private func setUpDownloads() async {
        downloads = DownloadManager(system: BackgroundDownloader.shared, store: store, files: files)
        downloads.onChange = { [weak self] in self?.downloadsVersion += 1 }
        downloads.onBatchFailed = { [weak self] in self?.alert = AlertSpec(title: "部分下载失败，请稍后重试") }
        downloads.onDiskFull = { [weak self] in self?.alert = AlertSpec(title: "手机存储空间不足，下载失败") }
        player.onDamaged = { [weak self] id in
            guard let self else { return }
            self.downloads.removeDownload(id)
            self.alert = AlertSpec(title: "这一集的下载文件已损坏，请重新下载")
        }
        await reconcileDownloads()
    }

    /// 主页上的封面先在后台下好（只存磁盘，已有的跳过）：打开主页时多数直接是图，不先看到占位色。
    /// 新课程是大卡片（要原图）；编辑精选和各分类行是小卡片（640 小图），每行只取前 4 张（第一屏能看到的加一点）。
    private static func prefetchHomeCovers(_ home: HomeData) {
        let large = home.ongoing.map { ($0.coverPath, Int.max) }
        let small = (home.featured + home.categories.flatMap { $0.series.prefix(4) }).map { ($0.coverPath, COVER_THUMB_WIDTHS.last!) }
        ImageLoader.shared.prefetch((large + small).map { (path: $0.0, requested: $0.1) })
    }

    func onForeground() {
        guard phase == .ready else { return }
        core.onForeground()
        Task { await reconcileDownloads() }
        // 在别处（系统下载）可能变了：重读一次
        downloadsVersion += 1
    }

    func onBackground() {
        core.onBackground()
        BackgroundRefresh.schedule()
        Task { await widgets.writeNow() }
    }

    /// 对账（启动、回到前台）：系统后台会话里还在跑的任务不算中断。
    func reconcileDownloads() async {
        let active = await BackgroundDownloader.shared.activeTasks()
        downloads.reconcile(active: active)
    }

    // MARK: 播放页

    func openPlayer() {
        guard player.current != nil else { return }
        playerOpen = true  // 系统 sheet 自带弹出动画
        OrientationLock.shared.playerOpen = true
    }

    func closePlayer() {
        playerOpen = false
        OrientationLock.shared.playerOpen = false
    }

    /// 播放页“前往课程”：下面已经是这门课就只收起播放页。
    func goToSeries(_ seriesId: String) {
        closePlayer()
        if nav.isShowingSeries(seriesId) { return }
        nav.push(.series(seriesId))
    }

    // MARK: 下载

    /// 有网就下，不分 Wi-Fi 还是流量、不提示；没网直接提示，不排队。
    private func requireNetwork() -> Bool {
        if Connectivity.shared.connected { return true }
        alert = AlertSpec(title: "网络异常，请检查网络后重试")
        return false
    }

    func download(_ items: [DlItem]) {
        guard !items.isEmpty, requireNetwork() else { return }
        covers.save(seriesId: items[0].seriesId, coverPath: store.seriesCoverPath(items[0].seriesId))
        downloads.enqueue(items)
    }

    /// 继续已暂停的（从头下）。
    func resumeDownloads(seriesId: String?, episodeId: String? = nil) {
        guard requireNetwork() else { return }
        if let e = episodeId {
            // 只继续这一集；记录没了就不动（不能变成继续整门课，和 Android 一致）
            if let r = store.getDownload(e) { downloads.enqueue([r.item]) }
            return
        }
        downloads.resumePaused(seriesId: seriesId)
    }

    func dlItem(episodeId: String) -> DlItem? {
        guard let i = try? store.getEpisodeInfo(episodeId) else { return nil }
        return DlItem(
            episodeId: i.episodeId, seriesId: i.seriesId, seriesTitle: i.seriesTitle, episodeTitle: i.episodeTitle, pos: i.pos,
            audioPath: i.audioPath)
    }

    func deleteDownload(_ episodeId: String) {
        stopIfCurrent(episodeId)
        downloads.removeDownload(episodeId)
    }

    /// 删一门课的下载：正在放这门课里的一集就先停掉。
    func deleteSeriesDownloads(_ seriesId: String) {
        if let c = player.current, c.seriesId == seriesId { stopIfCurrent(c.episodeId) }
        downloads.removeSeries(seriesId)
    }

    /// 停掉正在放的这一集时播放页也收起来：只清掉当前集，播放页虽然不画了，“播放页开着”却一直留着
    /// （弹窗只往播放页上挂、横屏不锁、点胶囊播放会自己弹出播放页）。
    private func stopIfCurrent(_ episodeId: String) {
        guard player.current?.episodeId == episodeId else { return }
        player.stopIfCurrent(episodeId)
        closePlayer()
    }
}
