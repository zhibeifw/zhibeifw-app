import Foundation

// 各处用到的纯逻辑（与 Android Logic.kt 逐条一致）。

// MARK: - 版本号

/// 只允许“数字.数字.数字”（可少写后面的段，缺的按 0），逐段按整数比较，绝不做字符串比较。
func parseVersion(_ v: Any?) -> [String]? {
    guard let s = v as? String, s.range(of: "^[0-9]+(\\.[0-9]+){0,2}$", options: .regularExpression) != nil else { return nil }
    var parts = s.split(separator: ".").map { p -> String in
        let t = p.drop(while: { $0 == "0" })
        return t.isEmpty ? "0" : String(t)
    }
    while parts.count < 3 { parts.append("0") }
    return parts
}

/// -1（a 较旧）、0（相同）、1（a 较新）；任一方格式不合法返回 nil。每段不设上限：先比位数、再逐位比。
func compareVersions(_ a: Any?, _ b: Any?) -> Int? {
    guard let pa = parseVersion(a), let pb = parseVersion(b) else { return nil }
    for i in 0..<3 {
        let x = pa[i], y = pb[i]
        if x.count != y.count { return x.count < y.count ? -1 : 1 }
        if x != y { return x < y ? -1 : 1 }
    }
    return 0
}

// MARK: - 时间与文字格式

let MINUS = "\u{2212}"

/// 全 App 统一的时间写法：分钟:秒，不分小时（113:32）。
func clock(_ sec: Double) -> String {
    let s = Int(max(0, (sec.isFinite ? sec : 0).rounded(.down)))
    return String(format: "%02d:%02d", s / 60, s % 60)
}

func remainingClock(_ position: Double, _ duration: Double) -> String { MINUS + clock(max(0, duration - position)) }

func sleepLabel(_ secondsLeft: Double?) -> String { secondsLeft == nil ? "zZ 本集结束" : "zZ \(clock(secondsLeft!))" }

enum PillKind { case new, half, done }
struct PillState: Equatable { var kind: PillKind; var text: String }
struct Prog: Equatable { var position: Double; var duration: Double; var completed: Bool }

private func minutes(_ sec: Double) -> Int { max(1, Int((sec / 60).rounded())) }

/// 单集播放胶囊的三种状态。
func pillState(_ p: Prog?, knownDuration: Double = 0) -> PillState {
    let fresh = PillState(kind: .new, text: knownDuration > 0 ? "\(minutes(knownDuration)) 分钟" : "播放")
    guard let p else { return fresh }
    if p.completed { return PillState(kind: .done, text: p.duration > 0 ? "\(minutes(p.duration)) 分钟" : "已听完") }
    if p.position > 0 && p.duration > 0 { return PillState(kind: .half, text: "剩 \(clock(max(0, p.duration - p.position)))") }
    return fresh
}

func progressRatio(_ position: Double, _ duration: Double) -> Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }

func seriesStatusText(_ status: String?) -> String { status == "completed" ? "已完结" : "更新中" }

/// 系列页信息行分类名之后的那段：“ · 共 N 节课 · 更新中”（有分类名时前面带“ · ”，没有集时省掉节数）。
func seriesInfoText(category: Bool, count: Int, status: String?) -> String {
    (category ? " · " : "") + (count > 0 ? "共 \(count) 节课 · " : "") + seriesStatusText(status)
}

// MARK: - 搜索的文字统一

private let invisibleRanges: [ClosedRange<UInt32>] = [
    0x0000...0x001F, 0x007F...0x009F, 0x200B...0x200F, 0x2028...0x202E, 0x2060...0x2064, 0xFEFF...0xFEFF,
]

/// 目录里的课程名和用户输入共用：去控制/零宽字符、NFKC（全角转半角）、小写、空白并一、去首尾空白。
func normalizeText(_ s: String) -> String {
    var scalars = String.UnicodeScalarView()
    for u in s.unicodeScalars where !invisibleRanges.contains(where: { $0.contains(u.value) }) { scalars.append(u) }
    let t = String(scalars).precomposedStringWithCompatibilityMapping.lowercased()
    let parts = t.split(whereSeparator: { $0.isWhitespace })
    return parts.joined(separator: " ")
}

let MAX_QUERY_LENGTH = 30

// MARK: - 封面占位色、分类方块

private func fnv(_ id: String, salt: UInt32 = 0) -> UInt32 {
    var h: UInt32 = 0x811c9dc5 ^ salt
    for c in id.utf16 { h ^= UInt32(c); h = h &* 0x01000193 }
    return h
}

func placeholderIndex(_ id: String) -> Int { Int(fnv(id) % UInt32(Tok.ContentPalette.colors.count)) }
func placeholderColor(_ id: String) -> ZColor { Tok.ContentPalette.colors[placeholderIndex(id)] }

let PALETTE_NAMES = ["orange", "blue", "purple", "pink", "teal", "olive", "green", "brown"]
/// 分类方块多出的 10 种颜色名（顺序对应 Tok.ContentPalette.categoryExtraColors）；封面占位色块不用它们
let CATEGORY_EXTRA_COLOR_NAMES = ["red", "amber", "magenta", "indigo", "slate", "forest", "cocoa", "cyan", "wine", "charcoal"]
let DEFAULT_ICON = "book-outline"
let RANDOM_ICONS = [
    "school-outline", "shield-checkmark-outline", "planet-outline", "infinite-outline", "bulb-outline", "flower-outline",
    "book-outline", "leaf-outline", "accessibility-outline", "flame-outline", "library-outline", "chatbubble-ellipses-outline",
    "sunny-outline", "moon-outline", "star-outline", "heart-outline", "cloudy-outline", "water-outline",
]

func isPaletteName(_ v: Any?) -> Bool {
    (v as? String).map { PALETTE_NAMES.contains($0) || CATEGORY_EXTRA_COLOR_NAMES.contains($0) } ?? false
}
func isValidColorSetting(_ v: Any?) -> Bool { (v as? String) == "random" || isPaletteName(v) }
func isValidIconSetting(_ v: Any?) -> Bool {
    guard let s = v as? String else { return false }
    if s == "random" { return true }
    return s.utf16.count >= 1 && s.utf16.count <= 40 && s.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil
}

func resolveCategoryColor(_ color: String?, id: String) -> ZColor {
    if let c = color, let i = PALETTE_NAMES.firstIndex(of: c) { return Tok.ContentPalette.colors[i] }
    if let c = color, let k = CATEGORY_EXTRA_COLOR_NAMES.firstIndex(of: c) { return Tok.ContentPalette.categoryExtraColors[k] }
    return placeholderColor(id)
}

func resolveCategoryIcon(_ icon: String?, id: String, known: (String) -> Bool = Icons.exists) -> String {
    if icon == "random" { return RANDOM_ICONS[Int(fnv(id, salt: 0x5a) % UInt32(RANDOM_ICONS.count))] }
    if let i = icon, isValidIconSetting(i), known(i) { return i }
    return DEFAULT_ICON
}

// MARK: - 本机文件名（两端逐位一致）

func fileKey(_ id: String) -> String {
    let safe =
        id.utf8.count >= 1 && id.utf8.count <= 64
        && id.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F || $0 == 0x2D
        }
    if safe { return id }
    var a: UInt32 = 0x811c9dc5
    var b: UInt32 = 0x9747b28c
    for c in id.utf16 {
        a = (a ^ UInt32(c)) &* 0x01000193
        b = (b ^ UInt32(c)) &* 0x5bd1e995
        b = b ^ (b >> 15)
    }
    return "h_" + String(format: "%08x%08x", a, b)
}

func orphanCoverKeys(_ onDisk: [String], seriesWithDownloads: [String]) -> [String] {
    let keep = Set(seriesWithDownloads.map(fileKey))
    return onDisk.filter { !keep.contains($0) }
}

func orphanPartKeys(_ onDisk: [String], keepEpisodeIds: [String]) -> [String] {
    let keep = Set(keepEpisodeIds.map(fileKey))
    return onDisk.filter { !keep.contains($0) }
}

/// 资料库音频目录里没有下载记录对应的文件名（keep：各条记录的本地文件名）。
func orphanAudioNames(_ onDisk: [String], keep: [String]) -> [String] {
    let k = Set(keep)
    return onDisk.filter { !k.contains($0) }
}

/// 写文件出错是不是因为存储空间不足；其它错误按普通失败处理。
func isOutOfSpace(_ error: Error) -> Bool {
    var e: NSError? = error as NSError
    while let n = e {
        if n.domain == NSCocoaErrorDomain && n.code == NSFileWriteOutOfSpaceError { return true }
        if n.domain == NSPOSIXErrorDomain && n.code == Int(ENOSPC) { return true }
        e = n.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return false
}

// MARK: - 下载

/// 整份下载收到的回复算不算整份文件：200；或者 206 且 Content-Range 从 0 开始（真机上系统后台下载服务会自己分段取）。
func isWholeFileResponse(status: Int, contentRange: String?) -> Bool {
    if status == 200 { return true }
    guard status == 206 else { return false }
    guard let cr = contentRange?.lowercased().trimmingCharacters(in: .whitespaces) else { return true }  // 系统没把这个头交出来：交给大小检查
    return cr.hasPrefix("bytes 0-")
}

// MARK: - 播放

let PLAYBACK_RATES: [Double] = Tok.RatePicker.rates.map(Double.init)
let SLEEP_MINUTES = [60, 45, 30, 15, 10, 5]

/// 睡眠定时用的时钟：开机以来的秒数（CLOCK_MONOTONIC，含休眠，不受改系统时间影响）。
func sleepClock() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }

enum SleepSetting: Equatable {
    case off, end
    /// deadline：到点的时刻（sleepClock 的秒数）
    case timer(deadline: Double, minutes: Int)
    var choiceId: String {
        switch self {
        case .off: return "off"
        case .end: return "end"
        case .timer(_, let m): return "m\(m)"
        }
    }
    func secondsLeft(now: Double) -> Double? {
        if case .timer(let d, _) = self { return max(0, (d - now).rounded(.up)) }
        return nil
    }
}

struct SleepChoice: Identifiable { let id: String; let title: String; let minutes: Int? }
let SLEEP_CHOICES: [SleepChoice] =
    [SleepChoice(id: "end", title: "单集结束时", minutes: nil)]
    + SLEEP_MINUTES.map { SleepChoice(id: "m\($0)", title: $0 == 60 ? "1 小时" : "\($0) 分钟", minutes: $0) }
    + [SleepChoice(id: "off", title: "关闭", minutes: nil)]

enum PlayContext: Equatable {
    case series(String), library(String), single
}

func pickNext(_ ordered: [String], current: String) -> String? {
    guard let i = ordered.firstIndex(of: current), i + 1 < ordered.count else { return nil }
    return ordered[i + 1]
}

let COMPLETED_TAIL_SECONDS: Double = 30
func isNearEnd(_ position: Double, _ duration: Double) -> Bool { duration > 0 && position >= duration - COMPLETED_TAIL_SECONDS }

/// 列表里正在播放的这一集用播放器的实时位置。
func liveProgress(currentId: String?, position: Double, duration: Double, active: Bool, episodeId: String, fromDb: Prog?) -> Prog? {
    if currentId == episodeId && duration > 0 {
        if let db = fromDb, db.completed, !active { return db }
        return Prog(position: position, duration: duration, completed: false)
    }
    return fromDb
}

// MARK: - 单集“•••”菜单里的下载项

enum DlStatus: String, Equatable { case queued, downloading, paused, done }
enum DlMenuAction { case download, pause, resume, cancel, delete }
struct DlMenuItem: Equatable { let action: DlMenuAction; let title: String; let icon: String; let destructive: Bool }

func downloadMenuItems(_ status: DlStatus?, canDownload: Bool = true) -> [DlMenuItem] {
    switch status {
    case .done: return [DlMenuItem(action: .delete, title: "删除下载", icon: "trash-outline", destructive: true)]
    case .queued, .downloading:
        return [
            DlMenuItem(action: .pause, title: "暂停下载", icon: "pause-circle-outline", destructive: false),
            DlMenuItem(action: .cancel, title: "取消下载", icon: "close-circle-outline", destructive: false),
        ]
    case .paused:
        return [
            DlMenuItem(action: .resume, title: "继续下载", icon: "arrow-down-circle-outline", destructive: false),
            DlMenuItem(action: .cancel, title: "取消下载", icon: "close-circle-outline", destructive: false),
        ]
    case nil:
        return canDownload ? [DlMenuItem(action: .download, title: "下载", icon: "arrow-down-circle-outline", destructive: false)] : []
    }
}

// MARK: - 防双击压两层页面

final class PushGuard {
    private var lastAt: [String: Double] = [:]
    private var shown = Set<String>()
    let windowMs: Double
    let now: () -> Double
    init(windowMs: Double = 700, now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.windowMs = windowMs; self.now = now
    }
    func allow(_ key: String) -> Bool {
        if shown.contains(key) { return false }
        let t = now()
        if let p = lastAt[key], t - p < windowMs { return false }
        lastAt[key] = t
        return true
    }
    func setShown(_ key: String, _ on: Bool) { if on { shown.insert(key) } else { shown.remove(key) } }
}

// MARK: - 同步时机

let FOREGROUND_SYNC_MIN_GAP_MS: Double = 60_000
func shouldSyncOnForeground(now: Double, lastSyncAt: Double, syncing: Bool) -> Bool {
    !syncing && now - lastSyncAt >= FOREGROUND_SYNC_MIN_GAP_MS
}
let LAUNCH_FRESH_MAX_MS: Double = 3000
func launchFreshWaitMs(online: Bool, elapsedMs: Double) -> Double { online ? max(0, LAUNCH_FRESH_MAX_MS - elapsedMs) : 0 }

// MARK: - 更新检查

let CHECK_INTERVAL_MS: Double = 24 * 3600 * 1000
let REMIND_LATER_MS: Double = 7 * 24 * 3600 * 1000

func shouldAutoCheck(lastCheckedAt: Double?, now: Double) -> Bool {
    guard let l = lastCheckedAt else { return true }
    return now - l >= CHECK_INTERVAL_MS || now < l
}

enum UpdateChannel { case site, store }
enum UpdateDecision: Equatable { case none, optional(version: String, apkPath: String), outdated(version: String, apkPath: String) }

func decideUpdate(current: String, _ u: UpgradeFile, channel: UpdateChannel) -> UpdateDecision {
    guard let vsMin = compareVersions(current, u.minVersion), let vsLatest = compareVersions(current, u.latestVersion) else { return .none }
    if vsMin == -1 { return .outdated(version: u.latestVersion, apkPath: u.apkPath) }
    if channel == .site && vsLatest == -1 { return .optional(version: u.latestVersion, apkPath: u.apkPath) }
    return .none
}

// MARK: - 域名顺序

func orderOrigins(remembered: String?, saved: [String], builtin: [String]) -> [String] {
    var out: [String] = []
    func add(_ o: String?) { if let o, !out.contains(o) { out.append(o) } }
    add(remembered)
    saved.forEach(add)
    builtin.forEach(add)
    return out
}

// MARK: - 封面解码尺寸档位

/// 封面按显示宽度解码；宽度按 256 像素一档往上取整，相近的尺寸共用一份解码结果
/// （播放页、系列页、卡片之间切换时不必每次重新解码，也就不会先闪一下色块）。
let COVER_PIXEL_STEP = 256
func coverBucket(_ px: Int) -> Int { max(COVER_PIXEL_STEP, (px + COVER_PIXEL_STEP - 1) / COVER_PIXEL_STEP * COVER_PIXEL_STEP) }

/// 封面小图（由发布脚本生成，规则和这里一致）：
/// 封面文件名在扩展名前加“-宽度”，如 中观/入中论讲解/cover.jpg → cover-640.jpg。
let COVER_THUMB_WIDTHS = [320, 640]
func coverThumbPath(_ path: String, width: Int) -> String {
    guard let dot = path.lastIndex(of: "."), !path[dot...].contains("/") else { return path }
    return "\(path[..<dot])-\(width)\(path[dot...])"
}
/// 按显示需要的宽度（像素）挑文件：不超过 320 用 320 小图，不超过 640 用 640 小图，再大用原图（只会挑够大的，不会放大变糊）。
func coverSourcePath(_ path: String, requestedPx: Int) -> String {
    guard let w = COVER_THUMB_WIDTHS.first(where: { requestedPx <= $0 }) else { return path }
    return coverThumbPath(path, width: w)
}
/// 视图向加载器要的宽度：用小图的范围里取小图的宽度，再大按 256 一档（尺寸小幅变化时不必重新取图）。
/// 视图还没量出宽度（0）时返回 0，调用方据此先不取图。
func coverRequestPx(_ px: Int) -> Int { px <= 0 ? 0 : COVER_THUMB_WIDTHS.first(where: { px <= $0 }) ?? coverBucket(px) }

// MARK: - 资料库的节数文字

/// 全部下完：“3 节”；还有在下载 / 排队 / 暂停的：“3 节 · 已下载 1 节”。
func libraryCountText(total: Int, done: Int) -> String {
    done >= total ? "\(total) 节" : "\(total) 节 · 已下载 \(done) 节"
}

/// 资料库列表行用：分成两行（行里文字和封面并排、太窄，放一行会被折断）。全部下完只有“3 节”。
func libraryCountLines(total: Int, done: Int) -> [String] {
    done >= total ? ["\(total) 节"] : ["\(total) 节", "已下载 \(done) 节"]
}
