import Foundation
import os

/// 开发版的小组件诊断日志（.notice 级别才会存下来；正式版不编进去）
enum WidgetLog {
    #if DEBUG
    static let log = Logger(subsystem: "com.zhibeifw.app", category: "Widget")
    static func note(_ s: String) {
        log.notice("\(s, privacy: .public)")
        print("[Widget] \(s)")  // 用 devicectl --console 启动 App 时能直接看到
    }
    #else
    static func note(_ s: String) {}
    #endif
}

/// App 和小组件之间传的数据：App 写一份 JSON 和几张小封面到共享目录（App Group），小组件只读不写。
/// 小组件进程读不了 App 的数据库，也不联网，所以显示用的东西都在这里备好。

/// 一门课（或这门课的某一集）
struct WidgetItem: Codable, Hashable {
    var seriesId: String
    var seriesTitle: String
    /// 最新课程、继续播放：要播的那一集；编辑精选、收藏：没有
    var episodeId: String?
    var episodeTitle: String?
    /// 共享目录 covers 里的文件名；还没有封面图时为空，显示占位色
    var cover: String?
    /// 没有封面时的占位色（ARGB），和 App 里同一门课的色块一样
    var color: UInt32
}

/// 继续播放：App 里正在播放的这一集；App 没在播时是最近播放里最近一条没听完的
struct WidgetNowPlaying: Codable, Hashable {
    var item: WidgetItem
    var position: Double
    var duration: Double
    var playing: Bool
    /// App 里当前载入的就是这一集（点小组件打开播放页；否则进这门课的课程页）
    var loaded: Bool
}

struct WidgetSnapshot: Codable, Hashable {
    var nowPlaying: WidgetNowPlaying?
    /// 最新课程：主页“新课程”里每门课的最新一集
    var latest: [WidgetItem] = []
    var featured: [WidgetItem] = []
    var favorites: [WidgetItem] = []
}

/// 小组件的种类（kind），App 刷新时用
enum WidgetKinds {
    static let nowPlaying = "NowPlaying"
    static let latest = "Latest"
    static let featured = "Featured"
    static let favorites = "Favorites"
}

/// 共享目录里的文件。App Group 写在 Info.plist 的 ZBFWAppGroup（开发版、正式版各一个，互不串数据）。
enum WidgetStore {
    static var groupId: String? { Bundle.main.object(forInfoDictionaryKey: "ZBFWAppGroup") as? String }

    static var dir: URL? {
        guard let id = groupId, !id.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)?
            .appendingPathComponent("Widgets", isDirectory: true)
    }
    static var coversDir: URL? { dir?.appendingPathComponent("covers", isDirectory: true) }
    private static var snapshotFile: URL? { dir?.appendingPathComponent("snapshot.json") }

    static func read() -> WidgetSnapshot {
        guard let f = snapshotFile else { WidgetLog.note("读：没有共享目录 group=\(groupId ?? "nil")"); return WidgetSnapshot() }
        guard let d = try? Data(contentsOf: f) else { WidgetLog.note("读：文件读不到 \(f.path)"); return WidgetSnapshot() }
        guard let s = try? JSONDecoder().decode(WidgetSnapshot.self, from: d) else { WidgetLog.note("读：解析失败"); return WidgetSnapshot() }
        return s
    }

    /// 内容没变就不写，返回 false（不用刷新小组件）
    @discardableResult
    static func write(_ s: WidgetSnapshot) -> Bool {
        guard let f = snapshotFile, let d = try? JSONEncoder().encode(s) else { WidgetLog.note("写：没有共享目录"); return false }
        if (try? Data(contentsOf: f)) == d { return false }
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? d.write(to: f, options: .atomic)) != nil
    }

    static func coverURL(_ name: String?) -> URL? {
        guard let name, !name.isEmpty else { return nil }
        return coversDir?.appendingPathComponent(name)
    }
}

/// 点小组件打开 App 的链接
enum WidgetLink {
    static let scheme = "zhibeifw"

    /// 进这门课的课程页
    case series(String)
    /// 打开播放页；App 里已经没有在放的一集时进这门课
    case player(seriesId: String)

    var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        switch self {
        case .series(let id): c.host = "series"; c.queryItems = [URLQueryItem(name: "id", value: id)]
        case .player(let id): c.host = "player"; c.queryItems = [URLQueryItem(name: "id", value: id)]
        }
        return c.url!
    }

    init?(_ url: URL) {
        guard url.scheme == Self.scheme,
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
            !id.isEmpty
        else { return nil }
        switch url.host {
        case "player": self = .player(seriesId: id)
        case "series": self = .series(id)
        default: return nil
        }
    }
}
