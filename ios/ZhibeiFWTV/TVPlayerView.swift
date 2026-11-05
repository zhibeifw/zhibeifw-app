import SwiftUI

/// 全屏播放页：封面、集名、进度，下面是后退 15 秒 / 播放暂停 / 前进 30 秒。
/// 遥控器：播放/暂停键随时可用（系统远程控制命令）；返回键收起播放页，声音照常播。
struct TVPlayerView: View {
    @Environment(AppCore.self) private var core
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let p = core.player, let c = p.current {
            HStack(alignment: .center, spacing: 100) {
                CoverImage(path: c.info.coverPath, colorId: c.seriesId, radius: 20)
                    .frame(width: 800, height: TVLayout.coverHeight(800))
                VStack(alignment: .leading, spacing: 28) {
                    Text(c.info.seriesTitle).font(.title3).foregroundStyle(.secondary).lineLimit(2)
                    Text(c.info.episodeTitle).font(.title2).fontWeight(.semibold).lineLimit(3)
                    if let err = p.error {
                        Text(errorText(err)).foregroundStyle(C.danger)
                        if err == .cannotPlay { Button("重试") { p.retry() } }
                    } else {
                        ProgressView(value: progressRatio(p.position, p.duration))
                        HStack {
                            Text(clock(p.position))
                            Spacer()
                            // 开了睡眠定时：右边显示定时（和 iPhone 一样），否则是剩余时间
                            switch p.sleep {
                            case .end: Text(sleepLabel(nil))
                            case .timer: Text(sleepLabel(p.sleepLeft ?? 0))
                            case .off: Text(p.duration > 0 ? remainingClock(p.position, p.duration) : "")
                            }
                        }
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        HStack(spacing: 40) {
                            Button { p.seek(by: -SEEK_BACK_SECONDS) } label: {
                                Image(systemName: "gobackward.\(Int(SEEK_BACK_SECONDS))")
                            }
                            Button { p.toggle() } label: {
                                Image(systemName: p.looksPlaying ? "pause.fill" : "play.fill")
                            }
                            Button { p.seek(by: SEEK_FORWARD_SECONDS) } label: {
                                Image(systemName: "goforward.\(Int(SEEK_FORWARD_SECONDS))")
                            }
                        }
                        .font(.title2)
                        TVPlayerMenus(player: p, now: c)
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
            }
            .padding(TVLayout.pageMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // tvOS 全屏弹出的页面默认是透明的（后面的课程页会透出来），要自己铺满背景：
            // 不透明的底色上，铺一层放大、模糊、调淡的封面（和系统“音乐”“播客”的播放页一样）
            .background {
                ZStack {
                    C.background
                    CoverImage(path: c.info.coverPath, colorId: c.seriesId, radius: 0)
                        .blur(radius: 80)
                        .opacity(0.35)
                }
                .ignoresSafeArea()
            }
            // 遥控器的播放/暂停键走系统的远程控制命令（PlayerController 里已注册），这里不再处理，免得按一下切两次
            .onExitCommand { dismiss() }
        } else {
            // 播放器停了（比如这一集被标为已听完）：没什么可显示的，收起
            Color.clear.onAppear { dismiss() }
        }
    }

    fileprivate func errorText(_ e: PlayerError) -> String {
        switch e {
        case .cannotPlay: "暂时无法播放，请检查网络后重试"
        case .damaged: "这一集的文件已损坏"
        case .gone: "这一集已下架"
        }
    }
}

/// 播放页下面一排菜单：倍速、睡眠定时、更多（标记已听完、收藏课程、前往课程）。文字和 iPhone 的一样。
private struct TVPlayerMenus: View {
    @Environment(AppCore.self) private var core
    @Environment(TVModel.self) private var model
    let player: PlayerController
    let now: NowPlaying
    @State private var favorite = false
    @State private var completed = false

    var body: some View {
        HStack(spacing: 40) {
            Menu {
                ForEach(PLAYBACK_RATES, id: \.self) { r in
                    Button { player.setRate(r) } label: { checkLabel(rateMenuTitle(r), player.rate == r) }
                }
            } label: {
                Text(String(format: "%g×", player.rate))
            }
            Menu {
                ForEach(SLEEP_CHOICES) { ch in
                    Button { player.setSleep(sleepSetting(ch)) } label: { checkLabel(ch.title, player.sleep.choiceId == ch.id) }
                }
            } label: {
                Image(systemName: player.sleep == .off ? "moon" : "moon.fill")
            }
            Menu {
                Button {
                    core.markCompleted(now.episodeId, seriesId: now.seriesId, completed: !completed)
                } label: {
                    Label(completed ? "标记为未听完" : "标记为已听完", systemImage: "checkmark.circle")
                }
                Button {
                    core.toggleFavorite(now.seriesId, title: now.info.seriesTitle, coverPath: now.info.coverPath)
                } label: {
                    Label(favorite ? "取消收藏课程" : "收藏课程", systemImage: favorite ? "bookmark.fill" : "bookmark")
                }
                Button { model.goToSeries(now.seriesId) } label: {
                    Label("前往课程", systemImage: "arrow.forward.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
        // 收藏、已听完变了（或换了一集）就重读；不在每次进度刷新时读库
        .task(id: "\(now.episodeId)|\(core.progressVersion)|\(core.favoritesVersion)") {
            favorite = core.store.isFavorite(now.seriesId)
            completed = core.store.loadProgress(now.episodeId)?.completed ?? false
        }
    }

    /// 单选菜单里的一项：选中的前面打勾。
    @ViewBuilder private func checkLabel(_ title: String, _ checked: Bool) -> some View {
        if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}
