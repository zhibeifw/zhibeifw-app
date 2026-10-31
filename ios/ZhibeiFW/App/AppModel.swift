import SwiftUI
import Observation
import SQLite3

enum Route: Hashable {
    case category(String)
    case series(String)
    case recent, favorites, library
    case libraryCourse(String)
    case about
}

enum Tab: Hashable { case home, categories, library, search }

enum Phase: Equatable {
    case launching
    case initializing(attempt: Int, failed: Bool)
    case ready
    case dbError
}

struct AlertButton: Identifiable {
    let id = UUID()
    var title: String
    var role: ButtonRole? = nil
    var action: () -> Void = {}
}
struct AlertSpec: Identifiable {
    let id = UUID()
    var title: String
    var message: String? = nil
    var buttons: [AlertButton] = [AlertButton(title: "好")]
}

/// 全 App 的状态与动作。页面只读它、调它，不各自保存一份播放或下载状态。
@MainActor
@Observable
final class AppModel {
    @ObservationIgnored let files = AppFiles()
    @ObservationIgnored private(set) var store: Store!
    private(set) var player: PlayerController!
    private(set) var downloads: DownloadManager!

    var phase: Phase = .launching
    var home = HomeData()
    /// 主页顶部“无法更新，显示的是上一次更新的内容”。
    var syncFailed = false
    /// “此版本过旧”提示条（本次运行内关闭后不再显示）。
    var outdated = false
    var outdatedDismissed = false
    /// 后台自动检查更新进行中（启动、切回前台时）：主页顶部显示“正在更新…”。下拉刷新有系统转圈，不算
    private(set) var autoUpdating = false
    @ObservationIgnored var lastSyncAt: Double = 0
    @ObservationIgnored var syncing = false
    @ObservationIgnored private var inflightSync: Task<SyncSummary, Never>?
    /// 用户数据变了（进度、收藏、下载……）：各页面据此重新读取。
    var dataVersion = 0
    var catalogVersion = 0

    var tab: Tab = .home
    var homePath: [Route] = []
    var categoriesPath: [Route] = []
    var libraryPath: [Route] = []
    var searchPath: [Route] = []
    var playerOpen = false
    var navCollapsed = false
    @ObservationIgnored var nav = NavCollapse()
    var alert: AlertSpec?
    var sheet: SheetSpec?
    /// 搜索框的文字（iOS 26 搜索框在底部“搜索”标签上，由根视图持有；按键盘“搜索”时 searchSubmitted 加一）
    var searchQuery = ""
    var searchSubmitted = 0
    @ObservationIgnored let pushGuard = PushGuard()

    init() {}

    // MARK: 启动

    func boot() async {
        let t0 = Date()
        files.prepare()
        do {
            let db = try SQLiteDB(path: files.dbPath.path)
            let backup = files.backupPath.path
            do {
                _ = try Migrator.migrate(
                    db,
                    beforeUserMigration: { _, _ in
                        try? FileManager.default.removeItem(atPath: backup); try Migrator.backupUserTables(db, to: backup)
                    })
            } catch {
                // 失败重试一次，仍失败就提示并停下
                _ = try Migrator.migrate(db)
            }
            store = Store(db: db)
        } catch {
            NSLog("数据库打开或升级失败：\(error)")
            phase = .dbError
            return
        }
        importV1Prefs()
        player = PlayerController(store: store, files: files)
        downloads = DownloadManager(system: BackgroundDownloader.shared, store: store, files: files)
        downloads.onChange = { [weak self] in self?.dataVersion += 1 }
        downloads.onBatchFailed = { [weak self] in self?.alert = AlertSpec(title: "部分下载失败，请稍后重试") }
        downloads.onDiskFull = { [weak self] in self?.alert = AlertSpec(title: "手机存储空间不足，下载失败") }
        player.onProgressSaved = { [weak self] in self?.dataVersion += 1 }
        player.onDamaged = { [weak self] id in
            guard let self else { return }
            self.downloads.removeDownload(id)
            self.alert = AlertSpec(title: "这一集的下载文件已损坏，请重新下载")
        }
        Network.shared.onOriginChange = { OriginWatcher.shared.bump() }
        await reconcileDownloads()

        if store.isInitialized {
            loadHome()
            // 有网络时等联网检查最多到启动后约 3 秒；没网不等
            let online = Connectivity.shared.connected
            let wait = launchFreshWaitMs(online: online, elapsedMs: Date().timeIntervalSince(t0) * 1000)
            if wait > 0 {
                let syncTask = Task { await self.syncCatalog(userInitiated: false) }
                let timeout = Task { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000)) }
                await withTaskGroup(of: Void.self) { g in
                    g.addTask { _ = await syncTask.value }
                    g.addTask { await timeout.value }
                    await g.next()
                    g.cancelAll()
                }
                timeout.cancel()
            } else {
                Task { await self.syncCatalog(userInitiated: false) }
            }
            phase = .ready
            Task { await self.checkUpgrade(manual: false) }
        } else {
            await runInitialization()
        }
        Connectivity.shared.onReconnect.append { [weak self] in
            guard let self, case .initializing(_, true) = self.phase else { return }
            Task { await self.runInitialization() }
        }
    }

    func runInitialization() async {
        phase = .initializing(attempt: 1, failed: false)
        let ok = await CatalogSync.initializeWithRetry(store: store, net: Network.shared) { [weak self] n in
            self?.phase = .initializing(attempt: n, failed: false)
        }
        if ok {
            loadHome()
            phase = .ready
            lastSyncAt = Date().timeIntervalSince1970 * 1000
            Task { await self.checkUpgrade(manual: false) }
        } else {
            phase = .initializing(attempt: CatalogSync.initAttempts, failed: true)
        }
    }

    /// 从 v1.0 的 ExpoSQLiteStorage 读出线路相关的小偏好。只读一次。
    private func importV1Prefs() {
        guard !Prefs.d.bool(forKey: Prefs.kMigratedV1) else { return }
        defer { Prefs.d.set(true, forKey: Prefs.kMigratedV1) }
        guard FileManager.default.fileExists(atPath: files.v1KVPath.path), let kv = try? SQLiteDB(path: files.v1KVPath.path) else { return }
        for key in [Prefs.kLastService, Prefs.kDomains] {
            if let v = (try? kv.first("SELECT value FROM storage WHERE key = ?", [key]))??.optStr("value") {
                if key == Prefs.kLastService ? isHttpsOrigin(v) : parseDomains(v) != nil { Prefs.d.set(v, forKey: key) }
            }
        }
    }

    func loadHome() {
        home = (try? store.loadHome()) ?? HomeData()
        catalogVersion += 1
        prefetchHomeCovers()
    }

    /// 主页上的封面先在后台下好（只存磁盘，已有的跳过）：打开主页时多数直接是图，不先看到占位色。
    /// 新课程是大卡片（要原图）；编辑精选和各分类行是小卡片（640 小图），每行只取前 4 张（第一屏能看到的加一点）。
    private func prefetchHomeCovers() {
        let large = home.ongoing.map { ($0.coverPath, Int.max) }
        let small = (home.featured + home.categories.flatMap { $0.series.prefix(4) }).map { ($0.coverPath, COVER_THUMB_WIDTHS.last!) }
        ImageLoader.shared.prefetch((large + small).map { (path: $0.0, requested: $0.1) })
    }

    /// 同步目录。userInitiated：主页下拉刷新。有新内容就立刻换上主页。
    @discardableResult
    /// 取 index.json 只有这几处：启动、切回前台（自动，主页顶栏显示“正在更新…”）、下拉刷新、刷新网络线路。
    /// 点开课程、在“最近”里点已下架的课都只看本机目录，不联网。
    func syncCatalog(userInitiated: Bool) async -> SyncSummary? {
        // 已经在更新（启动、回到前台时的自动更新）：等它做完，不另起一次；直接返回的话，下拉刷新的转圈会一闪就没
        if let running = inflightSync {
            let s = await running.value
            if userInitiated {
                loadHome()
                if s.failed { syncFailed = true }
            }
            return s
        }
        syncing = true
        if !userInitiated { autoUpdating = true }
        defer { syncing = false; autoUpdating = false }
        let task = Task { await CatalogSync.sync(store: store, net: Network.shared) }
        inflightSync = task
        let s = await task.value
        inflightSync = nil
        lastSyncAt = Date().timeIntervalSince1970 * 1000
        // 有新内容立刻换上；用户下拉刷新则完成后一律重读
        if userInitiated || s.changed { loadHome() }
        // 提示条：试遍线路仍失败、且手机连着网（用户主动刷新时不论有没有网都显示）
        if s.failed { syncFailed = userInitiated || Connectivity.shared.connected } else { syncFailed = false }
        return s
    }

    func onForeground() {
        guard phase == .ready else { return }
        if shouldSyncOnForeground(now: Date().timeIntervalSince1970 * 1000, lastSyncAt: lastSyncAt, syncing: syncing) {
            Task { await syncCatalog(userInitiated: false) }
        }
        Task { await reconcileDownloads() }
        player.refreshSleepDisplay()
        dataVersion += 1
    }

    func onBackground() {
        player?.saveNow()
    }

    /// 对账（启动、回到前台）：系统后台会话里还在跑的任务不算中断。
    func reconcileDownloads() async {
        let active = await BackgroundDownloader.shared.activeIds()
        downloads.reconcile(active: active)
    }

    // MARK: 更新检查（iOS 只看 minVersion）

    func checkUpgrade(manual: Bool) async {
        let now = Date().timeIntervalSince1970 * 1000
        let last = Prefs.d.object(forKey: Prefs.kUpdateChecked) as? Double
        guard manual || shouldAutoCheck(lastCheckedAt: last, now: now) else {
            if let body = Prefs.d.string(forKey: Prefs.kUpdateBody), let u = parseUpgrade(body) { applyUpgrade(u) }
            return
        }
        let r = await Network.shared.request(
            UPGRADE_PATH, etag: Prefs.d.string(forKey: Prefs.kUpdateEtag), maxBytes: FileKind.upgrade.limit)
        switch r {
        case .ok(let data, let etag):
            guard let u = parseUpgrade(data) else { return }
            Prefs.d.set(String(data: data, encoding: .utf8), forKey: Prefs.kUpdateBody)
            Prefs.d.set(etag, forKey: Prefs.kUpdateEtag)
            Prefs.d.set(now, forKey: Prefs.kUpdateChecked)
            applyUpgrade(u)
        case .notModified:
            Prefs.d.set(now, forKey: Prefs.kUpdateChecked)
            if let body = Prefs.d.string(forKey: Prefs.kUpdateBody), let u = parseUpgrade(body) { applyUpgrade(u) }
        default: break
        }
    }

    private func applyUpgrade(_ u: UpgradeFile) {
        if case .outdated = decideUpdate(current: AppInfo.version, u, channel: .store) { outdated = true } else { outdated = false }
    }

    // MARK: 导航

    var path: [Route] {
        get {
            switch tab {
            case .home: homePath
            case .categories: categoriesPath
            case .library: libraryPath
            case .search: searchPath
            }
        }
        set {
            switch tab {
            case .home: homePath = newValue
            case .categories: categoriesPath = newValue
            case .library: libraryPath = newValue
            case .search: searchPath = newValue
            }
        }
    }

    func push(_ r: Route) {
        guard pushGuard.allow("\(tab)-\(r)") else { return }
        path.append(r)
        resetNav()
    }

    func selectTab(_ t: Tab) {
        if tab == t { path = [] } else { tab = t }
        resetNav()
    }

    func resetNav() { nav.expand(); nav.reset(0); if navCollapsed { navCollapsed = false } }

    func feedScroll(_ y: Double) {
        if nav.feed(y) { withAnimation(.easeOut(duration: Double(Tok.Nav.collapseMs) / 1000)) { navCollapsed = nav.collapsed } }
    }

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
        if case .series(let s)? = path.last, s == seriesId { return }
        push(.series(seriesId))
    }

    // MARK: 播放入口

    /// 点一集的行：开始播放并打开全屏播放页。
    func playAndOpen(_ episodeId: String, ctx: PlayContext) {
        if player.current?.episodeId == episodeId && !player.looksPlaying && player.error == nil { player.resume(); openPlayer(); return }
        if player.current?.episodeId == episodeId { openPlayer(); return }
        if player.start(episodeId, ctx: ctx) { openPlayer() } else { episodeGone(episodeId) }
    }

    /// 胶囊里的播放/暂停：原地，不跳页。
    func togglePlay(_ episodeId: String, ctx: PlayContext) {
        if player.current?.episodeId == episodeId { player.toggle(); return }
        if !player.start(episodeId, ctx: ctx) { episodeGone(episodeId) }
    }

    private func episodeGone(_ episodeId: String) {
        alert = AlertSpec(title: "这一集已下架")
    }

    /// “最近”里点某一集：目录里没有时先取一次最新目录确认。
    func playFromRecent(_ row: RecentRow, open: Bool) {
        if !row.gone || store.getDownload(row.episodeId)?.state == .done {
            if open { playAndOpen(row.episodeId, ctx: .single) } else { togglePlay(row.episodeId, ctx: .single) }
            return
        }
        // 本机目录里没有、也没下载过，就是已下架。只看本机目录，不联网（只有启动和下拉刷新取 index.json）
        alert = AlertSpec(title: store.seriesExists(row.seriesId) ? "这一集已下架" : "这门课已下架")
    }

    // MARK: 进度、收藏

    func markCompleted(_ episodeId: String, seriesId: String, completed: Bool) {
        if completed { player.stopAsCompleted(episodeId) }
        let info = try? store.getEpisodeInfo(episodeId)
        try? store.markCompleted(
            episodeId, seriesId: seriesId, completed: completed, seriesTitle: info?.seriesTitle ?? "",
            episodeTitle: info?.episodeTitle ?? "", coverPath: info?.coverPath ?? "")
        dataVersion += 1
    }

    func toggleFavorite(_ seriesId: String, title: String, coverPath: String) {
        if store.isFavorite(seriesId) {
            try? store.removeFavorite(seriesId)
        } else {
            try? store.addFavorite(seriesId, title: title, coverPath: coverPath)
        }
        dataVersion += 1
    }

    // MARK: 下载

    /// 有网就下，不分 Wi-Fi 还是流量、不提示；没网直接提示，不排队。
    private func requireNetwork() -> Bool {
        if Connectivity.shared.connected { return true }
        alert = AlertSpec(title: "网络异常，请检查网络后重试")
        return false
    }

    func download(_ items: [DlItem], single: Bool) {
        guard !items.isEmpty, requireNetwork() else { return }
        saveCoverLocally(seriesId: items[0].seriesId)
        downloads.enqueue(items)
    }

    /// 继续已暂停的（从头下）。
    func resumeDownloads(seriesId: String?, single: Bool = false, episodeId: String? = nil) {
        guard requireNetwork() else { return }
        if let e = episodeId, let r = store.getDownload(e) {
            downloads.enqueue([r.item])
        } else {
            downloads.resumePaused(seriesId: seriesId)
        }
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

    /// 下载时把这门课的封面存一份到本地（资料库与离线锁屏用）。
    private func saveCoverLocally(seriesId: String) {
        let dest = files.coverFile(seriesId: seriesId)
        guard !FileManager.default.fileExists(atPath: dest.path), let cover = store.seriesCoverPath(seriesId), !cover.isEmpty else {
            return
        }
        Task.detached {
            guard let origin = await Network.shared.ensureRoutes(), let url = buildUrl(origin, cover),
                let (tmp, resp) = try? await URLSession.shared.download(from: url), (resp as? HTTPURLResponse)?.statusCode == 200
            else { return }
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.moveItem(at: tmp, to: dest)
            } else {
                try? FileManager.default.removeItem(at: tmp)
            }
        }
    }

    // MARK: 关于页

    func refreshRoutes() async -> String {
        let (origin, same) = await Network.shared.refreshRoutes()
        guard origin != nil else { return "暂时无法连接" }
        _ = await syncCatalog(userInitiated: true)
        return same ? "线路正常" : "已切换到备用线路，连接正常"
    }

}

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }
}

/// iOS 不需要申请下载相关的权限（占位，与 Android 的通知权限申请对称）。
