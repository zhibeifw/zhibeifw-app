import Foundation

// 外部数据（服务器 JSON）的校验。一律当作不可信输入——只当数据，先校验大小、类型、长度，再入库。
// 解析失败整个文件丢弃（调用方沿用本机旧数据）；文件里单条不合规的，整条丢弃。规则与 v1.0 validate.ts 逐条一致。

enum FileKind {
    case domains, index, upgrade
    var limit: Int {
        switch self {
        case .domains: return 10 * 1024
        case .index: return 10 * 1024 * 1024
        case .upgrade: return 10 * 1024
        }
    }
}

enum Limits {
    static let maxIdLength = 100
    static let maxTitleLength = 200
    static let maxDescriptionLength = 5000
    static let maxPathLength = 300
    static let maxDomainItems = 10
    static let maxEpisodeDuration = 24 * 3600
    static let maxUpdatedAt: Double = 1e11
    static let maxFeatured = 50
}

/// UTF-8 字节数。
func utf8ByteLength(_ s: String) -> Int { s.utf8.count }

// MARK: - 基本类型

/// 课程 ID、集 ID：文字（\p{L}）、十进制数字（\p{Nd}）、下划线、连字符，NFC 标准写法，1–100 个字符（按 UTF-16 码元计，与 v1.0 一致）。
func isValidId(_ v: Any?) -> Bool {
    guard let s = v as? String else { return false }
    let n = s.utf16.count
    guard n >= 1, n <= Limits.maxIdLength else { return false }
    guard s == s.precomposedStringWithCanonicalMapping else { return false }
    for u in s.unicodeScalars {
        if u == "_" || u == "-" { continue }
        let p = u.properties.generalCategory
        switch p {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: continue
        default: return false
        }
    }
    return true
}

/// 相对路径：不带协议和域名、不以“/”开头、不含“..”；另外不允许反斜杠、控制字符、空白、?、#。
func isValidRelativePath(_ v: Any?) -> Bool {
    guard let s = v as? String else { return false }
    let n = s.utf16.count
    if n == 0 || n > Limits.maxPathLength { return false }
    if s.hasPrefix("/") || s.contains("..") || s.contains("\\") { return false }
    if s.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil || s.contains("//") { return false }
    for u in s.utf16 where u <= 0x20 || u == 0x7F || u == 0x3F /* ? */ || u == 0x23 /* # */ { return false }
    return true
}

private func isTitle(_ v: Any?) -> String? {
    guard let s = v as? String else { return nil }
    let n = s.utf16.count
    guard n >= 1, n <= Limits.maxTitleLength, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return s
}

private let originRegex = try! NSRegularExpression(
    pattern:
        "^https://(\\[[0-9A-Fa-f:.]{2,45}\\]|[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*)(?::[0-9]{1,5})?$"
)

/// https://域名[:端口]，不带路径、不带结尾斜杠、不带账号密码。IPv6 须带方括号。
func isHttpsOrigin(_ v: Any?) -> Bool {
    guard let s = v as? String, s.utf16.count <= 253 else { return false }
    return originRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

/// 先看大小，再解析 JSON。JSONSerialization 能读出任意 JSON 值。
private func parseJson(_ data: Data, _ kind: FileKind) -> Any? {
    guard data.count <= kind.limit else { return nil }
    return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

/// JSONSerialization 把 true/false 也读成 NSNumber，这里区分出真正的数字。
private func number(_ v: Any?) -> Double? {
    guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    return n.doubleValue
}

// MARK: - domains.json

struct Domains: Equatable, Codable { var domains: [String] }

func parseDomains(_ data: Data) -> Domains? {
    guard let o = parseJson(data, .domains) as? [String: Any], let arr = o["domains"] as? [Any] else { return nil }
    var out: [String] = []
    for v in arr.prefix(Limits.maxDomainItems) where isHttpsOrigin(v) {
        let s = v as! String
        if !out.contains(s) { out.append(s) }
    }
    return out.isEmpty ? nil : Domains(domains: out)
}

func parseDomains(_ text: String) -> Domains? { parseDomains(Data(text.utf8)) }

// MARK: - index.json

struct CategoryEntry: Equatable { var id: String; var name: String; var icon: String?; var color: String? }
struct EpisodeEntry: Equatable { var id: String; var title: String; var audioPath: String; var duration: Int? }
struct SeriesEntry: Equatable {
    var id: String; var title: String; var categoryId: String; var coverPath: String; var status: String
    var description: String?; var episodes: [EpisodeEntry]; var updatedAt: Int64?
}
struct FeaturedEntry: Equatable { var title: String; var seriesId: String }
struct IndexFile: Equatable {
    var categories: [CategoryEntry]; var series: [SeriesEntry]; var featured: [FeaturedEntry]
    /// 分类页（方块网格）的先后，分类 ID 列表；只给分类页用，主页仍按 categories 的先后。没有就跟 categories 一样。
    var categoryOrder: [String] = []
}

func parseIndex(_ data: Data) -> IndexFile? {
    guard let o = parseJson(data, .index) as? [String: Any], let cats = o["categories"] as? [Any] else { return nil }
    var categories: [CategoryEntry] = []
    var series: [SeriesEntry] = []
    var catIds = Set<String>(), seriesSeen = Set<String>(), episodeSeen = Set<String>()
    var rawSeries = 0
    for cv in cats {
        guard let c = cv as? [String: Any], isValidId(c["id"]), let name = isTitle(c["name"]) else { continue }
        let cid = c["id"] as! String
        if catIds.contains(cid) { continue }
        catIds.insert(cid)
        categories.append(
            CategoryEntry(
                id: cid, name: name,
                icon: isValidIconSetting(c["icon"]) ? c["icon"] as? String : nil,
                color: isValidColorSetting(c["color"]) ? c["color"] as? String : nil))
        guard let list = c["series"] as? [Any] else { continue }
        for sv in list {
            rawSeries += 1
            guard let s = sv as? [String: Any], isValidId(s["id"]) else { continue }
            let sid = s["id"] as! String
            if seriesSeen.contains(sid) { continue }
            guard let title = isTitle(s["title"]), isValidRelativePath(s["coverPath"]) else { continue }
            guard let status = s["status"] as? String, status == "ongoing" || status == "completed" else { continue }
            seriesSeen.insert(sid)
            var episodes: [EpisodeEntry] = []
            if let eps = s["episodes"] as? [Any] {
                for ev in eps {
                    guard let e = ev as? [String: Any], isValidId(e["id"]) else { continue }
                    let eid = e["id"] as! String
                    guard !episodeSeen.contains(eid), let et = isTitle(e["title"]), isValidRelativePath(e["audioPath"]) else { continue }
                    episodeSeen.insert(eid)
                    var duration: Int? = nil
                    if let d = number(e["duration"]), d.isFinite, d > 0, d <= Double(Limits.maxEpisodeDuration) {
                        duration = Int(d.rounded())
                    }
                    episodes.append(EpisodeEntry(id: eid, title: et, audioPath: e["audioPath"] as! String, duration: duration))
                }
            }
            var description: String? = nil
            if let d = s["description"] as? String, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                description = String(utf16Prefix: d, Limits.maxDescriptionLength)
            }
            var updatedAt: Int64? = nil
            if let u = number(s["updatedAt"]), u.rounded() == u, u > 0, u < Limits.maxUpdatedAt { updatedAt = Int64(u) }
            series.append(
                SeriesEntry(
                    id: sid, title: title, categoryId: cid, coverPath: s["coverPath"] as! String, status: status,
                    description: description, episodes: episodes, updatedAt: updatedAt))
        }
    }
    if categories.isEmpty { return nil }
    if rawSeries > 0 && series.isEmpty { return nil }
    var featured: [FeaturedEntry] = []
    if let fs = o["featured"] as? [Any] {
        for fv in fs {
            if featured.count >= Limits.maxFeatured { break }
            if let f = fv as? [String: Any], let t = isTitle(f["title"]), isValidId(f["seriesId"]) {
                featured.append(FeaturedEntry(title: t, seriesId: f["seriesId"] as! String))
            }
        }
    }
    var order: [String] = []
    if let os = o["categoryOrder"] as? [Any] {
        for v in os where isValidId(v) && !order.contains(v as! String) { order.append(v as! String) }
    }
    return IndexFile(categories: categories, series: series, featured: featured, categoryOrder: order)
}

func parseIndex(_ text: String) -> IndexFile? { parseIndex(Data(text.utf8)) }

extension String {
    /// 按 UTF-16 码元取前 n 个（与 v1.0 的 slice 一致），不切断代理对。
    init(utf16Prefix s: String, _ n: Int) {
        if s.utf16.count <= n { self = s; return }
        var idx = s.utf16.index(s.utf16.startIndex, offsetBy: n)
        while idx > s.startIndex, String.Index(idx, within: s) == nil { idx = s.utf16.index(before: idx) }
        self = String(s[..<idx])
    }
}

// MARK: - upgrade.json

struct UpgradeFile: Equatable, Codable { var latestVersion: String; var minVersion: String; var apkPath: String }

func parseUpgrade(_ data: Data) -> UpgradeFile? {
    guard let o = parseJson(data, .upgrade) as? [String: Any] else { return nil }
    guard let cmp = compareVersions(o["minVersion"], o["latestVersion"]), cmp != 1 else { return nil }
    guard isValidRelativePath(o["apkPath"]), let apk = o["apkPath"] as? String, apk.hasPrefix("releases/") else { return nil }
    return UpgradeFile(latestVersion: o["latestVersion"] as! String, minVersion: o["minVersion"] as! String, apkPath: apk)
}

func parseUpgrade(_ text: String) -> UpgradeFile? { parseUpgrade(Data(text.utf8)) }
