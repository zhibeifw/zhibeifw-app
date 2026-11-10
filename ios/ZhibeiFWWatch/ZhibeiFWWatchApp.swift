import SwiftUI
import WatchKit
import Observation

@main
struct ZhibeiFWWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) private var delegate
    @State private var model = WatchModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(model)
                .environment(model.core)
                .task { await model.core.boot() }
                .onChange(of: phase) { _, phase in
                    if phase == .active { model.foreground() }
                    if phase == .background { model.core.onBackground() }
                }
        }
    }
}

@MainActor
@Observable
final class WatchModel {
    static let shared = WatchModel()
    let core = AppCore()
    var downloads: DownloadManager?
    var downloadVersion = 0
    var playerOpen = false
    var path: [WatchRoute] = []

    var versions: [Int] { [core.catalogVersion, core.progressVersion, core.favoritesVersion, downloadVersion] }

    init() {
        core.onReady = { [weak self] in self?.path = [.home] }
        core.presentPlayer = { [weak self] in self?.playerOpen = true }
        core.onStoreReady = { [weak self] in
            guard let self else { return }
            let manager = DownloadManager(system: BackgroundDownloader.shared, store: self.core.store, files: self.core.files)
            self.downloads = manager
            self.core.player.onDamaged = { [weak self] id in
                self?.downloads?.removeDownload(id)
                self?.core.alert = AlertSpec(title: "下载文件已损坏，请重新下载")
            }
            manager.onChange = { [weak self] in self?.downloadVersion += 1 }
            manager.onBatchFailed = { [weak self] in self?.core.alert = AlertSpec(title: "部分下载失败，请稍后重试") }
            manager.onDiskFull = { [weak self] in self?.core.alert = AlertSpec(title: "手表存储空间不足") }
            manager.reconcile(active: await manager.system.activeTasks())
        }
    }

    func foreground() {
        core.onForeground()
        guard let downloads else { return }
        Task { downloads.reconcile(active: await downloads.system.activeTasks()) }
    }

    func download(_ items: [DlItem]) {
        guard !items.isEmpty else { return }
        guard Connectivity.shared.connected else {
            core.alert = AlertSpec(title: "当前没有网络连接")
            return
        }
        for id in Set(items.map(\.seriesId)) {
            CoverArchive(files: core.files).save(seriesId: id, coverPath: core.store.seriesCoverPath(id))
        }
        downloads?.enqueue(items)
    }

    func download(_ ids: Set<String>) {
        download(
            ids.compactMap { id in
                guard let item = try? core.store.getEpisodeInfo(id) else { return nil }
                return DlItem(
                    episodeId: id, seriesId: item.seriesId, seriesTitle: item.seriesTitle,
                    episodeTitle: item.episodeTitle, pos: item.pos, audioPath: item.audioPath)
            }.sorted { $0.pos < $1.pos })
    }

    func resumeDownloads(seriesId: String? = nil) {
        let items = ((try? core.store.allDownloads()) ?? []).filter {
            $0.state == .paused && (seriesId == nil || $0.seriesId == seriesId)
        }.map(\.item)
        download(items)
    }

    func deleteDownloads(_ ids: Set<String>) {
        for id in ids {
            if core.player.current?.episodeId == id {
                core.player.stopIfCurrent(id)
                playerOpen = false
            }
            downloads?.removeDownload(id)
        }
    }

    func deleteSeriesDownloads(_ id: String) {
        deleteDownloads(Set(((try? core.store.downloadsOfSeries(id)) ?? []).map(\.episodeId)))
    }

    func showSeries(_ id: String) {
        playerOpen = false
        if path.last != .series(id) { path.append(.series(id)) }
    }

    func confirm(_ title: String, message: String? = nil, action: @escaping () -> Void) {
        core.alert = AlertSpec(
            title: title, message: message,
            buttons: [
                AlertButton(title: "取消", role: .cancel),
                AlertButton(title: "确定", role: .destructive, action: action),
            ])
    }

}

/// 保留系统后台任务，直到 URLSession 完成事件交付。
@MainActor
enum WatchDownloadEvents {
    static var tasks: [WKURLSessionRefreshBackgroundTask] = []
    static func finish() {
        tasks.forEach { $0.setTaskCompletedWithSnapshot(false) }
        tasks.removeAll()
    }
}

@MainActor
final class WatchDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        Task { await WatchModel.shared.core.boot() }
    }
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let download = task as? WKURLSessionRefreshBackgroundTask {
                WatchDownloadEvents.tasks.append(download)
                _ = BackgroundDownloader.shared
                Task { await WatchModel.shared.core.boot() }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
