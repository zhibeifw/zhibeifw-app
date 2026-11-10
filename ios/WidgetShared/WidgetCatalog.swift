import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// 小组件自己取“新课程”（App 没开着、很久没打开时，桌面上的最新课程也能更新）：
/// 每 2 小时左右系统让小组件刷新一次（时间表的 .after），刷新时取一次 index.json——先问服务器有没有变（ETag），没变什么都不做。
/// 只读新课程那几门（status 为 ongoing），排序、条数和 App 主页的“新课程”一样（更新时间新的在前，没有更新时间的排后，再按目录里的先后）。
/// 用 App 上次连通的线路（App 写在共享目录里），不自己换线路；线路不通就保持原样，等 App 下次打开时再换。
/// 只用来显示，不写 App 的数据库：App 下次同步时照常用自己的。
enum WidgetCatalog {
    /// 多久取一次（和小组件时间表一致）
    static let interval: TimeInterval = 2 * 3600
    /// 最新课程最多几门（和 App 写的一致）
    static let latestLimit = 7
    /// 封面宽度：大号小组件里最宽的封面约 160pt × 3 倍
    static let coverPx = 480
    /// 目录最大 10 MB（和 App 一样）
    private static let indexLimit = 10 * 1024 * 1024
    private static let coverLimit = 10 * 1024 * 1024

    /// 不用系统缓存（和 App 一样）：系统缓存会把服务器回的 304 换成一份完整的 200，ETag 就白问了
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    private static var etagFile: URL? { WidgetStore.dir?.appendingPathComponent("widget-index.etag") }
    private static var checkedFile: URL? { WidgetStore.dir?.appendingPathComponent("widget-checked") }

    /// 距上次检查（App 同步或小组件自己取）够 2 小时才取，免得小组件每次重画（点按钮等）都联网
    static func due(_ snap: WidgetSnapshot, now: Date = Date()) -> Bool {
        let mine = (checkedFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }).flatMap(Double.init) ?? 0
        let last = max(mine, snap.catalogCheckedAt ?? 0) / 1000
        return now.timeIntervalSince1970 - last >= interval - 10 * 60
    }

    /// 取一次；有新内容就写进共享目录并返回新的数据，否则返回 nil
    static func refresh(_ snap: WidgetSnapshot) async -> WidgetSnapshot? {
        guard let origin = snap.origin, isHttpsOrigin(origin), let url = buildUrl(origin, "index.json") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        let etag = etagFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        guard let (data, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse else {
            WidgetLog.note("小组件取目录：连不上")
            return nil
        }
        markChecked()
        if http.statusCode == 304 { WidgetLog.note("小组件取目录：没变"); return nil }
        guard http.statusCode == 200, data.count <= indexLimit, let latest = parseLatest(data) else {
            WidgetLog.note("小组件取目录：失败 \(http.statusCode)")
            return nil
        }
        var s = snap
        let colors = Dictionary(
            (snap.latest + [snap.nowPlaying?.item].compactMap { $0 }).map { ($0.seriesId, $0.color) }, uniquingKeysWith: { a, _ in a })
        let progress = Dictionary(
            snap.latest.compactMap { item -> (String, Double)? in
                guard let id = item.episodeId, let value = item.progress else { return nil }
                return (id, value)
            }, uniquingKeysWith: { a, _ in a })
        var items: [WidgetItem] = []
        for e in latest {
            let name = await cover(origin, e.coverPath)
            items.append(
                WidgetItem(
                    seriesId: e.id, seriesTitle: e.title, episodeId: e.lastId, episodeTitle: e.lastTitle, cover: name,
                    color: colors[e.id] ?? 0xFF8E8E93, progress: progress[e.lastId]))
        }
        s.latest = items
        s.latestFromWidgetAt = Date().timeIntervalSince1970 * 1000
        guard WidgetStore.write(s) else { return nil }
        if let f = etagFile, let e = http.value(forHTTPHeaderField: "ETag") { try? e.write(to: f, atomically: true, encoding: .utf8) }
        WidgetLog.note("小组件取目录：更新了 \(items.count) 门")
        return s
    }

    private static func markChecked() {
        guard let f = checkedFile else { return }
        try? String(Date().timeIntervalSince1970 * 1000).write(to: f, atomically: true, encoding: .utf8)
    }

    struct Latest { var id, title, coverPath, lastId, lastTitle: String; var updatedAt: Int64?; var pos: Int }

    /// 只读新课程：每门课的 ID、标题、封面、最后一集；规则和 App 的 parseIndex 一致（不合规的整条丢弃）
    static func parseLatest(_ data: Data) -> [Latest]? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let cats = o["categories"] as? [Any] else {
            return nil
        }
        var out: [Latest] = []
        var seen = Set<String>(), episodeSeen = Set<String>()
        var pos = 0
        for cv in cats {
            guard let c = cv as? [String: Any], isValidId(c["id"]), isTitle(c["name"]) != nil, let list = c["series"] as? [Any] else {
                continue
            }
            for sv in list {
                guard let s = sv as? [String: Any], isValidId(s["id"]) else { continue }
                let sid = s["id"] as! String
                if seen.contains(sid) { continue }
                guard let title = isTitle(s["title"]), isValidRelativePath(s["coverPath"]),
                    let status = s["status"] as? String, status == "ongoing" || status == "completed"
                else { continue }
                seen.insert(sid)
                pos += 1
                var last: (String, String)?
                for ev in (s["episodes"] as? [Any]) ?? [] {
                    guard let e = ev as? [String: Any], isValidId(e["id"]) else { continue }
                    let eid = e["id"] as! String
                    guard !episodeSeen.contains(eid), let et = isTitle(e["title"]), isValidRelativePath(e["audioPath"]) else { continue }
                    episodeSeen.insert(eid)
                    last = (eid, et)
                }
                guard status == "ongoing", let last else { continue }
                var updatedAt: Int64?
                if let u = jsonNumber(s["updatedAt"]), u.rounded() == u, u > 0, u < Limits.maxUpdatedAt { updatedAt = Int64(u) }
                out.append(
                    Latest(
                        id: sid, title: title, coverPath: s["coverPath"] as! String, lastId: last.0, lastTitle: last.1,
                        updatedAt: updatedAt, pos: pos))
            }
        }
        guard !seen.isEmpty else { return nil }
        out.sort { a, b in
            switch (a.updatedAt, b.updatedAt) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.pos < b.pos
            }
        }
        return Array(out.prefix(latestLimit))
    }

    /// 封面：共享目录里已有（App 存过）就用；没有就取 640 小图（服务器没有小图时取原图），缩到 480 宽存 JPEG。
    /// 文件名和 App 的一样（封面路径的 SHA-256），App 下次写数据时认得出
    private static func cover(_ origin: String, _ path: String) async -> String? {
        guard let dir = WidgetStore.coversDir else { return nil }
        let name = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined() + ".jpg"
        let f = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: f.path) { return name }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for src in [thumbPath(path, width: 640), path] {
            guard let u = buildUrl(origin, src),
                let (data, resp) = try? await session.data(for: URLRequest(url: u, timeoutInterval: 15)),
                (resp as? HTTPURLResponse)?.statusCode == 200, data.count <= coverLimit
            else { continue }
            if saveJPEG(data, to: f) { return name }
        }
        return nil
    }

    /// 封面小图的文件名：扩展名前加“-宽度”（发布脚本生成，规则和 App 的 coverThumbPath 一致）
    private static func thumbPath(_ path: String, width: Int) -> String {
        guard let dot = path.lastIndex(of: "."), !path[dot...].contains("/") else { return path }
        return "\(path[..<dot])-\(width)\(path[dot...])"
    }

    private static func saveJPEG(_ data: Data, to f: URL) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
            let img = CGImageSourceCreateThumbnailAtIndex(
                src, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: coverPx,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary),
            let dest = CGImageDestinationCreateWithURL(f as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
