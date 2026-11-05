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
                            Text(p.duration > 0 ? remainingClock(p.position, p.duration) : "")
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
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
            }
            .padding(TVLayout.pageMargin)
            // 遥控器的播放/暂停键走系统的远程控制命令（PlayerController 里已注册），这里不再处理，免得按一下切两次
            .onExitCommand { dismiss() }
        } else {
            // 播放器停了（比如这一集被标为已听完）：没什么可显示的，收起
            Color.clear.onAppear { dismiss() }
        }
    }

    private func errorText(_ e: PlayerError) -> String {
        switch e {
        case .cannotPlay: "暂时无法播放，请检查网络后重试"
        case .damaged: "这一集的文件已损坏"
        case .gone: "这一集已下架"
        }
    }
}
