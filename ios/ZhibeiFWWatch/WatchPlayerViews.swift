import SwiftUI
import WatchKit

struct WatchPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NowPlayingView()
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        WatchPlayerActionsView()
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("更多播放选项")
                }
            }
    }
}

private struct WatchPlayerFactsKey: Equatable {
    let episodeId: String?
    let versions: [Int]
}

struct WatchPlayerActionsView: View {
    @Environment(AppCore.self) private var core
    @Environment(WatchModel.self) private var model
    @State private var completed = false
    @State private var favorite = false
    @State private var download: DlRow?
    var body: some View {
        List {
            if let current = core.player.current {
                if core.player.error != nil { Button("重试播放") { core.player.retry() } }
                Button("前往课程") { model.showSeries(current.seriesId) }
                Button(favorite ? "取消收藏这门课" : "收藏这门课") {
                    core.toggleFavorite(current.seriesId, title: current.info.seriesTitle, coverPath: current.info.coverPath)
                }
                Button(completed ? "标记为未听完" : "标记为已听完") {
                    core.markCompleted(current.episodeId, seriesId: current.seriesId, completed: !completed)
                }
                WatchDownloadActionRows(id: current.episodeId, download: download) {
                    model.confirm("删除此下载？", message: "将停止当前播放，保留收听进度。") {
                        model.deleteDownloads([current.episodeId])
                    }
                }
            }
        }
        .navigationTitle("更多操作")
        .task(id: WatchPlayerFactsKey(episodeId: core.player.current?.episodeId, versions: model.versions)) {
            guard let current = core.player.current else { return }
            completed = core.store.loadProgress(current.episodeId)?.completed ?? false
            favorite = core.store.isFavorite(current.seriesId)
            download = core.store.getDownload(current.episodeId)
        }
    }
}

/// 单集下载入口共用系统按钮与侧滑操作，避免播放页和课程页出现不同的操作规则。
struct WatchDownloadActionRows: View {
    let id: String
    let download: DlRow?
    var canDownload = true
    var title: String? = nil
    let delete: () -> Void
    @Environment(WatchModel.self) private var model

    var body: some View {
        switch model.downloads?.items[id]?.status ?? download?.state {
        case .done:
            if let title {
                HStack {
                    Text(title)
                    Spacer()
                    Image(systemName: "arrow.down.circle.fill")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(title)，已下载")
                .swipeActions {
                    Button(role: .destructive, action: delete) {
                        Label("删除下载", systemImage: "trash")
                    }
                }
            } else {
                Button("删除下载", role: .destructive, action: delete)
            }
        case .queued, .downloading, .paused:
            let paused = (model.downloads?.items[id]?.status ?? download?.state) == .paused
            let ratio = model.downloads?.ratio(id) ?? 0
            Button {
                if paused {
                    if let download { model.download([download.item]) }
                } else {
                    model.downloads?.pause(id)
                }
            } label: {
                HStack {
                    if let title { Text(title); Spacer() }
                    Gauge(value: ratio) {
                        EmptyView()
                    } currentValueLabel: {
                        Image(systemName: paused ? "arrow.down" : "pause.fill")
                            .font(.title2)
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .frame(width: Tok.Component.EpisodeRow.gaugeNative, height: Tok.Component.EpisodeRow.gaugeNative)
                    .scaleEffect(Tok.Component.EpisodeRow.ring / Tok.Component.EpisodeRow.gaugeNative)
                    .frame(width: Tok.Component.EpisodeRow.ring, height: Tok.Component.EpisodeRow.ring)
                    .accessibilityHidden(true)
                    if title == nil {
                        Text(paused ? "继续下载" : "暂停下载")
                        Spacer()
                    }
                    Text(ratio, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
            }
            .accessibilityLabel("\(title ?? "下载")，\(paused ? "继续下载" : "暂停下载")，\(ratio.formatted(.percent.precision(.fractionLength(0))))")
            .swipeActions {
                Button(role: .destructive) {
                    model.downloads?.cancel(id)
                } label: {
                    Label("取消下载", systemImage: "xmark")
                }
            }
        case nil:
            if canDownload {
                Button {
                    model.download(Set([id]))
                } label: {
                    HStack {
                        Text(title ?? "下载这一集")
                        if title != nil { Spacer(); Image(systemName: "arrow.down.circle") }
                    }
                }.accessibilityLabel("下载\(title ?? "这一集")")
            }
        }
    }
}
