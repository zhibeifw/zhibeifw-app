import AppIntents
import Foundation

enum SiriPlaybackError: LocalizedError, CustomLocalizedStringResourceConvertible {
    case notReady, noRecent, unavailable, failed

    var errorDescription: String? { String(localized: localizedStringResource) }

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: return "课程目录尚未准备好，请先打开智悲佛网完成加载。"
        case .noRecent: return "还没有可以继续收听的课程，请指定课程和集数。"
        case .unavailable: return "找不到这一集，请重新选择课程和集数。"
        case .failed: return "暂时无法播放，请打开智悲佛网检查网络或音频状态。"
        }
    }
}

@MainActor
enum SiriPlayback {
    static var core: AppCore {
        #if os(watchOS)
        WatchModel.shared.core
        #elseif os(macOS)
        MacModel.shared.core
        #elseif os(visionOS)
        VisionModel.shared.core
        #elseif os(tvOS)
        TVModel.shared.core
        #else
        AppModel.shared.core
        #endif
    }

    static func ready() async throws -> AppCore {
        let core = core
        await core.boot()
        // 与小组件共用冷启动模型；界面已开始启动时等待其完成。
        for _ in 0..<100 where core.phase == .launching {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard core.phase == .ready else { throw SiriPlaybackError.notReady }
        return core
    }

    static func play(_ episodeID: String, seriesID: String? = nil) async throws {
        let core = try await ready()
        guard let info = try core.store.getEpisodeInfo(episodeID),
              seriesID == nil || info.seriesId == seriesID else { throw SiriPlaybackError.unavailable }
        try await start(core.player, episodeID: episodeID, context: seriesID.map { .series($0) } ?? .single)
    }

    static func start(_ player: PlayerController, episodeID: String, context: PlayContext) async throws {
        if player.current?.episodeId == episodeID {
            if !player.looksPlaying { player.resume() }
        } else {
            guard player.start(episodeID, ctx: context) else { throw SiriPlaybackError.unavailable }
        }
        // AudioPlaybackIntent 必须在开始出声后返回，避免后台冷启动在加载时被挂起。
        for _ in 0..<100 where !player.isPlaying && player.error == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard player.isPlaying else { throw SiriPlaybackError.failed }
    }
}

struct SiriCourse: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "课程")
    static let defaultQuery = SiriCourseQuery()
    var id: String
    var title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct SiriCourseQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [SiriCourse] {
        let core = try await SiriPlayback.ready()
        return try identifiers.compactMap { id in
            guard let row = try core.store.loadSeriesHeader(id) else { return nil }
            return SiriCourse(id: row.id, title: row.title)
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [SiriCourse] {
        let core = try await SiriPlayback.ready()
        let result = try core.store.searchSeries(string)
        // 语音点播不能把未匹配的课名缩短后悄悄换成另一门课。
        guard !result.fallback else { return [] }
        return result.rows.map { SiriCourse(id: $0.id, title: $0.title) }
    }

    @MainActor
    func suggestedEntities() async throws -> [SiriCourse] {
        let core = try await SiriPlayback.ready()
        return try core.store.loadFavorites().filter { !$0.gone }.map { SiriCourse(id: $0.id, title: $0.title) }
    }
}

struct SiriEpisode: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "集数")
    static let defaultQuery = SiriEpisodeQuery()
    var id: String
    var seriesID: String
    var title: String
    var courseTitle: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(courseTitle) \(title)")
    }
}

struct SiriEpisodeQuery: EntityStringQuery {
    @IntentParameterDependency<PlayCourseIntent>(\.$course) var intent

    @MainActor
    func entities(for identifiers: [String]) async throws -> [SiriEpisode] {
        let core = try await SiriPlayback.ready()
        return try identifiers.compactMap { id in
            guard let info = try core.store.getEpisodeInfo(id) else { return nil }
            return SiriEpisode(id: id, seriesID: info.seriesId, title: info.episodeTitle, courseTitle: info.seriesTitle)
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [SiriEpisode] {
        guard let course = intent?.course else { return [] }
        let core = try await SiriPlayback.ready()
        return try core.store.loadEpisodes(course.id).map {
            SiriEpisode(id: $0.id, seriesID: course.id, title: $0.title, courseTitle: course.title)
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [SiriEpisode] {
        if intent?.course != nil {
            return try await suggestedEntities().filter { SiriEpisodeName.matches($0.title, spoken: string) }
        }
        let core = try await SiriPlayback.ready()
        return try core.store.siriEpisodes(matching: string)
    }
}

struct ContinueListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "继续播放"
    static let description = IntentDescription("继续收听智悲佛网当前或最近未听完的一集。")

    @MainActor
    func perform() async throws -> some IntentResult {
        let core = try await SiriPlayback.ready()
        let id = try core.player.current?.episodeId ?? core.store.loadRecent(limit: 20)
            .first(where: { !$0.gone && !$0.progress.completed })?.episodeId
        guard let id else { throw SiriPlaybackError.noRecent }
        try await SiriPlayback.play(id)
        return .result()
    }
}

struct PlayCourseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "播放课程"
    static let description = IntentDescription("指定智悲佛网的课程和集数播放；未指定时询问，不自动选集。")

    @Parameter(title: "课程", requestValueDialog: "想听哪门课？") var course: SiriCourse
    @Parameter(title: "集数", requestValueDialog: "想听哪一集？") var episode: SiriEpisode

    static var parameterSummary: some ParameterSummary {
        Summary("播放\(\.$course)的\(\.$episode)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard episode.seriesID == course.id else { throw SiriPlaybackError.unavailable }
        try await SiriPlayback.play(episode.id, seriesID: course.id)
        return .result()
    }
}

struct PlayEpisodeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "播放指定的一集"
    @Parameter(title: "课程与集数", requestValueDialog: "想听哪门课的哪一集？") var episode: SiriEpisode
    static var parameterSummary: some ParameterSummary { Summary("播放\(\.$episode)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await SiriPlayback.play(episode.id, seriesID: episode.seriesID)
        return .result()
    }
}

#if !os(macOS) && !os(tvOS)
struct ListeningShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FavoriteCurrentCourseIntent(), phrases: [
            "用\(.applicationName)收藏这门课", "收藏\(.applicationName)当前课程"
        ], shortTitle: "收藏这门课", systemImageName: "bookmark")
        AppShortcut(intent: CompleteCurrentEpisodeIntent(), phrases: [
            "用\(.applicationName)把这一集标记为已听完", "标记\(.applicationName)当前一集为已听完"
        ], shortTitle: "标记为已听完", systemImageName: "checkmark.circle")
        AppShortcut(intent: SetListeningRateIntent(), phrases: [
            "把\(.applicationName)播放速度设为\(\.$rate)", "设置\(.applicationName)播放速度"
        ], shortTitle: "设置播放速度", systemImageName: "speedometer")
        AppShortcut(intent: SetListeningSleepIntent(), phrases: [
            "让\(.applicationName)\(\.$time)停止播放", "设置\(.applicationName)睡眠定时"
        ], shortTitle: "设置睡眠定时", systemImageName: "moon")
        AppShortcut(intent: CancelListeningSleepIntent(), phrases: [
            "取消\(.applicationName)的睡眠定时"
        ], shortTitle: "取消睡眠定时", systemImageName: "moon.slash")
        #if os(iOS) || os(watchOS)
        AppShortcut(intent: DownloadCurrentEpisodeIntent(), phrases: [
            "用\(.applicationName)下载这一集", "下载\(.applicationName)当前一集"
        ], shortTitle: "下载这一集", systemImageName: "arrow.down.circle")
        #endif
        AppShortcut(intent: ContinueListeningIntent(), phrases: [
            "用\(.applicationName)继续播放", "在\(.applicationName)继续收听"
        ], shortTitle: "继续播放", systemImageName: "play.fill")
        AppShortcut(intent: PlayCourseIntent(), phrases: [
            "用\(.applicationName)播放课程", "用\(.applicationName)播放\(\.$course)"
        ], shortTitle: "播放课程", systemImageName: "book")
        AppShortcut(intent: PlayEpisodeIntent(), phrases: [
            "用\(.applicationName)收听\(\.$episode)"
        ], shortTitle: "播放指定的一集", systemImageName: "play.circle")
    }
}
#endif
