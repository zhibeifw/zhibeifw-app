import AppIntents
import Foundation
import MediaIntents

@available(macOS 27.0, *)
@AppEntity(schema: .audio.podcastShow)
struct MacSiriCourse {
    static let defaultQuery = MacSiriCourseQuery()
    let id: String
    var title: String
    var showDescription: String?
    init(id: String, title: String) { self.id = id; self.title = title }
    var displayRepresentation: DisplayRepresentation { .init(title: "\(title)") }
}

@available(macOS 27.0, *)
@AppEntity(schema: .audio.podcastEpisode)
struct MacSiriEpisode {
    static let defaultQuery = MacSiriEpisodeQuery()
    let id: String
    var title: String
    var showName: String?
    var show: MacSiriCourse?
    var releaseDate: Date?
    var duration: Double?
    init(id: String, title: String, showName: String, show: MacSiriCourse?) {
        self.id = id; self.title = title; self.showName = showName; self.show = show
    }
    var displayRepresentation: DisplayRepresentation { .init(title: "\(showName ?? "") \(title)") }
}

@available(macOS 27.0, *)
struct MacSiriCourseQuery: EntityQuery, IntentValueQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [MacSiriCourse] {
        let core = try await SiriPlayback.ready()
        return try identifiers.compactMap { try MacSiriAudio.course($0, store: core.store) }
    }

    @MainActor
    func values(for input: AudioSearch) async throws -> [MacSiriCourse] {
        SiriControls.trace("MacSiriCourseQuery")
        let core = try await SiriPlayback.ready()
        return try MacSiriAudio.courses(input, store: core.store)
    }
}

@available(macOS 27.0, *)
struct MacSiriEpisodeQuery: EntityQuery, IntentValueQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [MacSiriEpisode] {
        let core = try await SiriPlayback.ready()
        return try identifiers.compactMap { try MacSiriAudio.episode($0, store: core.store) }
    }

    @MainActor
    func values(for input: AudioSearch) async throws -> [MacSiriEpisode] {
        SiriControls.trace("MacSiriEpisodeQuery")
        let core = try await SiriPlayback.ready()
        return try MacSiriAudio.episodes(input, store: core.store, currentID: core.player.current?.episodeId)
    }
}

@available(macOS 27.0, *)
enum MacSiriAudio {
    // 继续收听与课程点播使用不同实体标识，系统重新查询后仍保留播放上下文。
    static let resumePrefix = "resume:"

    static func episodeID(_ entityID: String) -> String {
        entityID.hasPrefix(resumePrefix) ? String(entityID.dropFirst(resumePrefix.count)) : entityID
    }
    static func course(_ id: String, store: Store) throws -> MacSiriCourse? {
        guard let row = try store.loadSeriesHeader(id) else { return nil }
        return MacSiriCourse(id: row.id, title: row.title)
    }

    static func episode(_ id: String, store: Store) throws -> MacSiriEpisode? {
        guard let row = try store.getEpisodeInfo(episodeID(id)) else { return nil }
        return MacSiriEpisode(
            id: id, title: row.episodeTitle, showName: row.seriesTitle,
            show: try course(row.seriesId, store: store))
    }

    static func courses(_ input: AudioSearch, store: Store) throws -> [MacSiriCourse] {
        switch input.criteria {
        case .searchQuery(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            guard try store.siriEpisodes(matching: text).isEmpty else { return [] }
            let result = try store.searchSeries(text)
            guard !result.fallback else { return [] }
            return try result.rows.compactMap { try course($0.id, store: store) }
        case .url(let urls):
            return try urls.compactMap { url in
                guard let link = WidgetLink(url) else { return nil }
                switch link {
                case .series(let id), .player(let id): return try course(id, store: store)
                }
            }
        case .unspecified: return []
        @unknown default: return []
        }
    }

    static func episodes(_ input: AudioSearch, store: Store, currentID: String?) throws -> [MacSiriEpisode] {
        switch input.criteria {
        case .searchQuery(let text):
            return try store.siriEpisodes(matching: text).compactMap { try episode($0.id, store: store) }
        case .unspecified:
            let id = try currentID ?? store.loadRecent(limit: 20).first { !$0.gone && !$0.progress.completed }?.episodeId
            guard let id, let item = try episode(resumePrefix + id, store: store) else { return [] }
            return [item]
        case .url: return []
        @unknown default: return []
        }
    }
}

@available(macOS 27.0, *)
@UnionValue
enum MacSiriAudioItem {
    case podcastShow(MacSiriCourse)
    case podcastEpisode(MacSiriEpisode)
}

@available(macOS 27.0, *)
@AppEnum(schema: .audio.playbackAttributes)
enum MacSiriPlaybackAttribute: String {
    case shuffle, `repeat`
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .shuffle: "随机播放", .repeat: "循环播放",
    ]
}

@available(macOS 27.0, *)
@AppEnum(schema: .audio.queueInsertionLocation)
enum MacSiriQueueLocation: String {
    case next, tail
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .next: "下一项播放", .tail: "最后播放",
    ]
}

@available(macOS 27.0, *)
@AppEntity(schema: .audio.warmupAudioQueueResult)
struct MacSiriWarmupResult: TransientAppEntity {
    var displayRepresentation: DisplayRepresentation { .init(title: "播放准备") }
}

enum MacSiriAudioError: Error, CustomLocalizedStringResourceConvertible {
    case unsupportedPlaybackMode
    var localizedStringResource: LocalizedStringResource {
        "智悲佛网暂不支持随机播放、循环播放或加入播放队列，请直接指定课程和集数播放。"
    }
}

@available(macOS 27.0, *)
@AppIntent(schema: .audio.playAudio)
struct MacSiriPlayAudioIntent: AudioPlaybackIntent {
    var audioEntity: MacSiriAudioItem
    var playbackAttributes: Set<MacSiriPlaybackAttribute>
    var warmupAudioQueueResult: MacSiriWarmupResult?
    var queueLocation: MacSiriQueueLocation?

    @MainActor
    func perform() async throws -> some IntentResult {
        SiriControls.trace("MacSiriPlayAudioIntent")
        // 目录播放遵循既有顺序，不把系统的队列请求偷偷改成立即播放。
        guard playbackAttributes.isEmpty, queueLocation == nil, warmupAudioQueueResult == nil else {
            throw MacSiriAudioError.unsupportedPlaybackMode
        }
        let core = try await SiriPlayback.ready()
        let selected: MacSiriEpisode
        switch audioEntity {
        case .podcastEpisode(let episode): selected = episode
        case .podcastShow(let course):
            let items = try core.store.loadEpisodes(course.id).compactMap { try MacSiriAudio.episode($0.id, store: core.store) }
            guard !items.isEmpty else { throw SiriPlaybackError.unavailable }
            let choice = try await $audioEntity.requestDisambiguation(
                among: items.map { MacSiriAudioItem.podcastEpisode($0) }, dialog: "想听哪一集？")
            guard case .podcastEpisode(let episode) = choice else { throw SiriPlaybackError.unavailable }
            selected = episode
        }
        guard let course = selected.show else { throw SiriPlaybackError.unavailable }
        try await SiriPlayback.play(
            MacSiriAudio.episodeID(selected.id),
            seriesID: selected.id.hasPrefix(MacSiriAudio.resumePrefix) ? nil : course.id)
        return .result()
    }
}
