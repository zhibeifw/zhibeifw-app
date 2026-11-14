import AppIntents

/// 小组件上的播放 / 暂停（继续播放的按钮、最新课程的每一行）。
/// AudioPlaybackIntent 在主 App 进程执行。
struct SetPlayingIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "播放或暂停"
    static let isDiscoverable = false

    @Parameter(title: "集") var episodeId: String
    // 保留参数以兼容系统已缓存的小组件动作。
    @Parameter(title: "播放") var play: Bool

    init() {}
    init(episodeId: String, play: Bool) {
        self.episodeId = episodeId
        self.play = play
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if ZBFW_IOS_APP
        await AppModel.shared.togglePlaybackFromWidget(episodeId)
        #elseif ZBFW_VISION_APP
        await VisionModel.shared.togglePlaybackFromWidget(episodeId)
        #elseif ZBFW_MAC_APP
        await MacModel.shared.togglePlaybackFromWidget(episodeId)
        #endif
        return .result()
    }
}
