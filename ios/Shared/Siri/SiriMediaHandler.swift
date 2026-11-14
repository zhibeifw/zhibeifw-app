#if !os(macOS) && !os(watchOS)
import Intents
import OSLog

/// Siri 的媒体点播入口；快捷指令与媒体意图最终使用同一个播放器。
final class SiriMediaHandler: NSObject, INPlayMediaIntentHandling {
    static let shared = SiriMediaHandler()
    static let log = Logger(subsystem: "com.zhibeifw.app", category: "SiriPlayback")

    func resolveMediaItems(for intent: INPlayMediaIntent,
                           with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void) {
        Self.log.notice("媒体点播：进入解析")
        Task { @MainActor in
            do {
                let core = try await SiriPlayback.ready()
                let selection = try SiriMediaSelection.resolve(intent, store: core.store)
                switch selection {
                case .resume:
                    completion([.notRequired()])
                case .missing:
                    completion([.unsupported()])
                case .items(let items, let needsChoice):
                    Self.log.notice("媒体点播：候选数=\(items.count) 需要选择=\(needsChoice)")
                    if items.count == 1, !needsChoice {
                        completion([.success(with: items[0])])
                    } else if items.count == 1 {
                        completion([.confirmationRequired(with: items[0])])
                    } else {
                        completion([.disambiguation(with: items)])
                    }
                }
            } catch {
                Self.log.error("媒体点播：目录尚未就绪")
                completion([.unsupported(forReason: .serviceUnavailable)])
            }
        }
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        Self.log.notice("媒体点播：进入播放回调")
        Task { @MainActor in
            do {
                let core = try await SiriPlayback.ready()
                switch try SiriMediaSelection.resolve(intent, store: core.store) {
                case .resume:
                    _ = try await ContinueListeningIntent().perform()
                case .items(let items, let needsChoice):
                    guard !needsChoice, items.count == 1,
                          let identifier = items[0].identifier,
                          identifier.hasPrefix(SiriMediaSelection.episodePrefix),
                          let info = try core.store.getEpisodeInfo(String(identifier.dropFirst(SiriMediaSelection.episodePrefix.count)))
                    else { throw SiriPlaybackError.unavailable }
                    try await SiriPlayback.play(info.episodeId, seriesID: info.seriesId)
                case .missing:
                    throw SiriPlaybackError.unavailable
                }
                Self.log.notice("媒体点播：已开始出声")
                completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
            } catch {
                Self.log.error("媒体点播：播放失败")
                completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            }
        }
    }
}

enum SiriMediaSelection {
    case resume, missing
    case items([INMediaItem], needsChoice: Bool)

    static let episodePrefix = "episode:"
    static let coursePrefix = "course:"

    static func resolve(_ intent: INPlayMediaIntent, store: Store) throws -> SiriMediaSelection {
        if let items = intent.mediaItems, items.count > 1 {
            return .items(items, needsChoice: true)
        }
        if let id = intent.mediaItems?.first?.identifier ?? intent.mediaSearch?.mediaIdentifier {
            if id.hasPrefix(episodePrefix) {
                guard let info = try store.getEpisodeInfo(String(id.dropFirst(episodePrefix.count))) else { return .missing }
                return .items([item(info)], needsChoice: false)
            }
            if id.hasPrefix(coursePrefix) {
                return try episodes(String(id.dropFirst(coursePrefix.count)), store: store)
            }
            return .missing
        }
        let name = intent.mediaSearch?.mediaName ?? intent.mediaItems?.first?.title
        let container = intent.mediaSearch?.albumName ?? intent.mediaContainer?.title
        let parts = [container, name].compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !parts.isEmpty else { return .resume }
        let spoken = parts.joined()
        let matches = try store.siriEpisodes(matching: spoken)
        if !matches.isEmpty {
            let items = matches.map {
                INMediaItem(identifier: episodePrefix + $0.id, title: $0.courseTitle + " " + $0.title,
                            type: .podcastEpisode, artwork: nil)
            }
            return .items(items, needsChoice: items.count != 1)
        }
        let result = try store.searchSeries(spoken)
        guard !result.fallback, !result.rows.isEmpty else { return .missing }
        if result.rows.count == 1 { return try episodes(result.rows[0].id, store: store) }
        return .items(result.rows.map {
            INMediaItem(identifier: coursePrefix + $0.id, title: $0.title, type: .podcastShow, artwork: nil)
        }, needsChoice: true)
    }

    private static func episodes(_ course: String, store: Store) throws -> SiriMediaSelection {
        guard let header = try store.loadSeriesHeader(course) else { return .missing }
        let rows = try store.loadEpisodes(course)
        guard !rows.isEmpty else { return .missing }
        return .items(rows.map {
            INMediaItem(identifier: episodePrefix + $0.id, title: header.title + " " + $0.title,
                        type: .podcastEpisode, artwork: nil)
        }, needsChoice: true)
    }

    private static func item(_ info: EpisodeInfo) -> INMediaItem {
        INMediaItem(identifier: episodePrefix + info.episodeId, title: info.seriesTitle + " " + info.episodeTitle,
                    type: .podcastEpisode, artwork: nil)
    }
}

#endif
