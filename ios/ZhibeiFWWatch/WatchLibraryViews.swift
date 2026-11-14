import SwiftUI

struct WatchLibraryHubView: View {
    var body: some View {
        List {
            NavigationLink(value: WatchRoute.recent) { Label("最近播放", systemImage: "clock") }
            NavigationLink(value: WatchRoute.favorites) { Label("收藏", systemImage: "bookmark") }
            NavigationLink(value: WatchRoute.downloads) { Label("已下载", systemImage: "arrow.down.circle") }
        }.navigationTitle("资料库")
    }
}

struct WatchRecentView: View {
    @Environment(AppCore.self) private var core
    @Environment(WatchModel.self) private var model
    @State private var rows: [RecentRow] = []
    var body: some View {
        List {
            if rows.isEmpty {
                Text("暂无收听记录")
            } else {
                WatchLibraryCount(text: "\(rows.count) 条记录")

            }
            ForEach(rows) { row in
                WatchEpisodeRow(
                    id: row.id, series: row.seriesId, title: row.epTitle, scope: .recent,
                    progress: row.progress, duration: row.epDuration ?? 0, subtitle: row.seriesTitle,
                    play: { core.playFromRecent(row, open: true) }, compactPlayback: true)
            }
        }
        .navigationTitle("最近播放")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空", systemImage: "trash", role: .destructive) {
                    model.confirm("清空最近列表？", message: "保留收听进度、已听完标记和下载。") { core.clearRecent() }
                }.disabled(rows.isEmpty)
            }
        }
        .task(id: model.versions) { rows = (try? core.store.loadRecent()) ?? [] }
    }
}

struct WatchFavoritesView: View {
    @Environment(AppCore.self) private var core
    @Environment(WatchModel.self) private var model
    @State private var rows: [FavoriteRow] = []
    var body: some View {
        List {
            if rows.isEmpty { Text("暂无收藏") } else { WatchLibraryCount(text: "\(rows.count) 门课") }
            ForEach(rows) { row in
                NavigationLink(value: WatchRoute.series(row.id)) {
                    WatchCourseLabel(
                        title: row.title, cover: row.coverPath, id: row.id,
                        subtitle: row.gone ? "已下架" : seriesStatusText(row.status))
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        core.removeFavorite(row.id)
                    } label: {
                        Label("取消收藏", systemImage: "bookmark.slash")
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                }
            }
        }
        .navigationTitle("收藏")
        .task(id: model.versions) { rows = (try? core.store.loadFavorites()) ?? [] }
    }
}

struct WatchDownloadLibraryView: View {
    @Environment(AppCore.self) private var core
    @Environment(WatchModel.self) private var model
    @State private var rows: [LibrarySeries] = []
    var body: some View {
        List {
            if rows.isEmpty {
                Text("暂无下载")
            } else {
                WatchLibraryCount(
                    text:
                        "\(rows.count) 门课 · \(libraryCountText(total: rows.reduce(0) { $0 + $1.n }, done: rows.reduce(0) { $0 + $1.done }))"
                )
                WatchDownloadControls()
            }
            ForEach(rows) { row in
                NavigationLink(value: WatchRoute.seriesDownloads(row.seriesId)) {
                    WatchCourseLabel(
                        title: row.seriesTitle, cover: row.coverPath, id: row.seriesId,
                        subtitle: libraryCountText(total: row.n, done: row.done))
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        model.confirm("删除这门课的所有下载？", message: "不会删除收藏和收听进度。") {
                            model.deleteSeriesDownloads(row.seriesId)
                        }
                    } label: {
                        Label("删除这门课的所有下载", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("已下载")
        .task(id: model.downloadVersion) { rows = (try? core.store.loadLibrary()) ?? [] }
    }
}

struct WatchDownloadControls: View {
    var series: String? = nil
    @Environment(AppCore.self) private var core
    @Environment(WatchModel.self) private var model
    var body: some View {
        let _ = model.downloadVersion
        let rows = ((try? core.store.allDownloads()) ?? []).filter { series == nil || $0.seriesId == series }
        WatchBatchDownloadButton(ids: rows.map(\.episodeId), series: series)
    }
}

struct WatchBatchDownloadButton: View {
    let ids: [String]
    var series: String? = nil
    @Environment(AppCore.self) private var core
    @Environment(WatchModel.self) private var model

    var body: some View {
        let _ = model.downloadVersion
        let states = ids.map { model.downloads?.items[$0]?.status ?? core.store.getDownload($0)?.state }
        Group {
            if states.contains(.queued) || states.contains(.downloading) {
                Button("暂停全部下载", systemImage: "pause.circle") { model.downloads?.pauseAll(seriesId: series) }
            } else if states.contains(.paused) {
                Button("继续下载", systemImage: "arrow.down.circle") { model.resumeDownloads(seriesId: series) }
            } else if !states.isEmpty && states.allSatisfy({ $0 == .done }) {
                if series != nil {
                    Button("删除这门课的所有下载", systemImage: "trash", role: .destructive) {
                        model.confirm("删除这门课的所有下载？", message: "不会删除收藏和收听进度。") {
                            model.deleteDownloads(Set(ids))
                        }
                    }
                }
            } else if series != nil {
                Button("下载全部", systemImage: "arrow.down.circle") { model.download(Set(ids)) }.disabled(ids.isEmpty)
            }
        }
        .swipeActions {
            if states.contains(.queued) || states.contains(.downloading) || states.contains(.paused) {
                Button(role: .destructive) {
                    model.downloads?.cancelSeries(series)
                } label: {
                    Label("取消全部下载", systemImage: "xmark")
                }
            }
        }
    }
}

struct WatchEpisodeActionsView: View {
    let id: String
    let series: String
    let title: String
    let scope: WatchPlayScope
    @Environment(AppCore.self) private var core
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var progress: Prog?
    @State private var download: DlRow?
    @State private var info: EpisodeInfo?
    var body: some View {
        List {
            Text(title).font(.headline)
            if info != nil {
                Button("播放", systemImage: "play.fill") { core.playAndOpen(id, ctx: scope.context(series)) }
            }
            NavigationLink(value: WatchRoute.series(series)) {
                Label("前往课程", systemImage: "arrow.forward.circle")
            }
            Button(progress?.completed == true ? "标记为未听完" : "标记为已听完",
                   systemImage: progress?.completed == true ? "rectangle.badge.minus" : "rectangle.badge.checkmark") {
                core.markCompleted(id, seriesId: series, completed: progress?.completed != true)
            }
            WatchDownloadActionRows(id: id, download: download, canDownload: info != nil) {
                model.confirm("删除此下载？") { model.deleteDownloads([id]) }
            }
        }
        .navigationTitle("更多操作")
        .task(id: model.versions) {
            progress = core.store.loadProgress(id)
            download = core.store.getDownload(id)
            info = try? core.store.getEpisodeInfo(id)
        }
    }
}

struct WatchLibraryCount: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .listRowBackground(Color.clear)
    }
}
