#if !os(tvOS)
import AppIntents
import Foundation
import OSLog

enum SiriControlError: LocalizedError, CustomLocalizedStringResourceConvertible {
    case noCurrent, offline, saveFailed, invalidOption
    var errorDescription: String? { String(localized: localizedStringResource) }

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noCurrent: return "当前没有正在收听的课程，请先播放一集。"
        case .offline: return "当前没有网络，暂时无法下载。"
        case .saveFailed: return "操作没有完成，请打开智悲佛网重试。"
        case .invalidOption: return "请选择智悲佛网支持的选项。"
        }
    }
}

@MainActor
enum SiriControls {
    static func trace(_ action: String) {
        #if DEBUG
        Logger(subsystem: "com.zhibeifw.app", category: "SiriControls").notice("AppIntent entered: \(action, privacy: .public)")
        #endif
    }

    static func current(_ core: AppCore) throws -> EpisodeInfo {
        guard let current = core.player.current else {
            trace("noCurrent")
            throw SiriControlError.noCurrent
        }
        return current.info
    }

    static func favorite(_ info: EpisodeInfo, store: Store) throws {
        guard !store.isFavorite(info.seriesId) else { return }
        try store.addFavorite(info.seriesId, title: info.seriesTitle, coverPath: info.coverPath)
    }
}

enum SiriRate: String, AppEnum {
    case slow = "0.8", normal = "1", medium = "1.3", faster = "1.5", fast = "1.8", double = "2"
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "播放速度")
    static let caseDisplayRepresentations: [SiriRate: DisplayRepresentation] = [
        .slow: "零点八倍", .normal: "一倍", .medium: "一点三倍",
        .faster: "一点五倍", .fast: "一点八倍", .double: "两倍"
    ]
    var value: Double { Double(rawValue)! }
}

enum SiriSleep: String, AppEnum {
    case five = "m5", ten = "m10", fifteen = "m15", thirty = "m30", fortyFive = "m45", sixty = "m60", end
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "停止播放时间")
    static let caseDisplayRepresentations: [SiriSleep: DisplayRepresentation] = [
        .five: "五分钟后", .ten: "十分钟后", .fifteen: "十五分钟后", .thirty: "三十分钟后",
        .fortyFive: "四十五分钟后", .sixty: "一小时后", .end: "本集结束时"
    ]
    func setting(now: Double = sleepClock()) throws -> SleepSetting {
        guard let choice = SLEEP_CHOICES.first(where: { $0.id == rawValue }) else { throw SiriControlError.invalidOption }
        return sleepSetting(choice, now: now)
    }
}

struct FavoriteCurrentCourseIntent: AppIntent {
    static let title: LocalizedStringResource = "收藏这门课"
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        SiriControls.trace("FavoriteCurrentCourseIntent")
        let core = try await SiriPlayback.ready()
        let info = try SiriControls.current(core)
        try SiriControls.favorite(info, store: core.store)
        core.favoritesVersion += 1
        return .result(dialog: "已收藏《\(info.seriesTitle)》。")
    }
}

struct CompleteCurrentEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "标记这一集为已听完"
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        SiriControls.trace("CompleteCurrentEpisodeIntent")
        let core = try await SiriPlayback.ready()
        let info = try SiriControls.current(core)
        core.markCompleted(info.episodeId, seriesId: info.seriesId, completed: true)
        guard core.store.loadProgress(info.episodeId)?.completed == true else { throw SiriControlError.saveFailed }
        return .result(dialog: "已将《\(info.seriesTitle)》\(info.episodeTitle)标记为已听完。")
    }
}

struct SetListeningRateIntent: AppIntent {
    static let title: LocalizedStringResource = "设置播放速度"
    @Parameter(title: "倍速", requestValueDialog: "要设置成几倍速？") var rate: SiriRate
    static var parameterSummary: some ParameterSummary { Summary("将播放速度设为\(\.$rate)") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        SiriControls.trace("SetListeningRateIntent")
        let core = try await SiriPlayback.ready()
        _ = try SiriControls.current(core)
        guard PLAYBACK_RATES.contains(rate.value) else { throw SiriControlError.invalidOption }
        core.player.setRate(rate.value)
        return .result(dialog: "播放速度已设为\(rate.rawValue)倍。")
    }
}

struct SetListeningSleepIntent: AppIntent {
    static let title: LocalizedStringResource = "设置睡眠定时"
    @Parameter(title: "停止时间", requestValueDialog: "什么时候停止播放？") var time: SiriSleep
    static var parameterSummary: some ParameterSummary { Summary("在\(\.$time)停止播放") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        SiriControls.trace("SetListeningSleepIntent")
        let core = try await SiriPlayback.ready()
        _ = try SiriControls.current(core)
        let setting = try time.setting()
        core.player.setSleep(setting)
        if case .timer(_, let minutes) = setting { return .result(dialog: "将在\(minutes)分钟后停止播放。") }
        return .result(dialog: "将在本集结束时停止播放。")
    }
}

struct CancelListeningSleepIntent: AppIntent {
    static let title: LocalizedStringResource = "取消睡眠定时"
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        SiriControls.trace("CancelListeningSleepIntent")
        let core = try await SiriPlayback.ready()
        core.player.setSleep(.off)
        return .result(dialog: "已取消睡眠定时。")
    }
}

#if os(iOS) || os(watchOS)
struct DownloadCurrentEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "下载这一集"
    // 下载管理器异步取得线路再交给URLSession；前台执行保证任务交付，不另造后台保活。
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        SiriControls.trace("DownloadCurrentEpisodeIntent")
        let core = try await SiriPlayback.ready()
        let info = try SiriControls.current(core)
        let state = core.store.getDownload(info.episodeId)?.state
        if state == .done { return .result(dialog: "这一集已经下载好了。") }
        if state == .queued || state == .downloading { return .result(dialog: "这一集已在下载队列中。") }
        guard Connectivity.shared.connected else { throw SiriControlError.offline }
        let item = DlItem(episodeId: info.episodeId, seriesId: info.seriesId, seriesTitle: info.seriesTitle,
                          episodeTitle: info.episodeTitle, pos: info.pos, audioPath: info.audioPath)
        #if os(watchOS)
        WatchModel.shared.download([item])
        #else
        AppModel.shared.download([item])
        #endif
        guard let after = core.store.getDownload(info.episodeId)?.state, after == .queued || after == .downloading || after == .done
        else { throw SiriControlError.saveFailed }
        return .result(dialog: "已将这一集加入下载队列。")
    }
}
#endif
#endif
