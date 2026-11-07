import AppIntents

/// 小组件上的播放 / 暂停（继续播放的按钮、最新课程的每一行）。
/// 小组件里用 Button(intent:)，创建时带上点了以后要切到的状态 play。
/// （试过 Toggle(isOn:intent:)：被点的那个小组件执行完后一直停在灰色不刷新；SetValueIntent 的 value 执行时是空的。）
/// 实现 AudioPlaybackIntent：系统在 App 的进程里执行（App 没开着就在后台启动它），不打开 App。App 和小组件都编译这个文件；小组件进程里 WidgetBridge 没接上，不会执行到。
struct SetPlayingIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "播放或暂停"
    static let isDiscoverable = false

    @Parameter(title: "集") var episodeId: String
    /// 打开 = 播这一集（不是当前这一集就换成它），关上 = 暂停
    @Parameter(title: "播放") var play: Bool

    init() {}
    init(episodeId: String, play: Bool) {
        self.episodeId = episodeId
        self.play = play
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await WidgetBridge.setPlaying?(episodeId, play)
        return .result()
    }
}

/// App 启动时接上，小组件的按钮通过它调 App
@MainActor
enum WidgetBridge {
    static var setPlaying: ((String, Bool) async -> Void)?
}
