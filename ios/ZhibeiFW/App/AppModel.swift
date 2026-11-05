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
            Task { await self.upgrade.check(manual: false) }
        }
        core.prefetchHomeCovers = { home in Self.prefetchHomeCovers(home) }
        core.presentPlayer = { [weak self] in self?.openPlayer() }
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

    func onBackground() { core.onBackground() }

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
        player.stopIfCurrent(episodeId)
        downloads.removeDownload(episodeId)
    }
}
