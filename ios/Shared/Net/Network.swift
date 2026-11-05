import Foundation
import Network

// 所有网络请求集中在这一个模块，便于以后加入 DoH 等。
// 地址一律是“当前可用的域名 + / + 相对路径”。只走 HTTPS（域名列表已校验；ATS 默认要求）。

enum NetConfig {
    /// 内置的域名（3 到 5 个，每个 App 版本换一批）。所有域名绑定同一个存储桶，内容完全一样。
    static let builtinDomains = ["https://zbfw.org", "https://zbfw.app"]
    static let raceStaggerMs: UInt64 = 1500
    static let raceTimeout: TimeInterval = 5
    /// 空闲超时：连续这么久没收到数据才算超时（URLSession 的 timeoutIntervalForRequest 就是这个语义）。
    static let idleTimeout: TimeInterval = 15
    static let headTimeout: TimeInterval = 5
    static let privacyURL = URL(string: "https://zhibeifw.com/privacy")!
    static let sourceURL = URL(string: "https://github.com/zhibeifw/zhibeifw-app")!
    /// App Store 链接（上架后由团队填；留空时“此版本过旧”提示条不显示“更新”按钮）。
    static let iosStoreURL = ""
}

enum NetResult: Equatable {
    case ok(Data, etag: String?)
    case notModified
    case notFound
    case error(String)
}

/// 小偏好（UserDefaults，可丢失）。
enum Prefs {
    static let d = UserDefaults.standard
    static let kLastService = "net.lastService"
    static let kDomains = "net.domains"
    static let kUpdateChecked = "update.lastCheckedAt"
    static let kUpdateEtag = "update.etag"
    static let kUpdateBody = "update.body"
    static let kMigratedV1 = "migrated.v1kv"
}

/// encodeURI 的等价物：保留 URL 里的保留字符和不需要编码的字符，其余（中文等）按 UTF-8 百分号编码。
func buildUrl(_ origin: String, _ path: String) -> URL? {
    var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    allowed.insert(charactersIn: ";,/?:@&=+$-_.!~*'()#")
    guard let enc = path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
    return URL(string: origin + "/" + enc)
}

/// 网络状态（NWPathMonitor）。“有没有网络连接”用系统的，不用“能否上网”检测。
@MainActor
final class Connectivity: ObservableObject {
    static let shared = Connectivity()
    /// 有没有网络（不再区分 Wi-Fi 还是流量）
    @Published private(set) var connected = true
    private let monitor = NWPathMonitor()
    var onReconnect: [() -> Void] = []

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let c = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let was = self.connected
                self.connected = c
                if c && !was { self.onReconnect.forEach { $0() } }
            }
        }
        monitor.start(queue: DispatchQueue(label: "net.monitor"))
    }
}

final class Network: @unchecked Sendable {
    static let shared = Network()

    private let session: URLSession
    private let lock = NSLock()
    private var service: String?
    private var lastKnown: String?
    private var resolving: Task<String?, Never>?
    /// 当前域名变化时通知（已显示的封面据此重新取图）。
    var onOriginChange: (() -> Void)?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let c = URLSessionConfiguration.default
            c.timeoutIntervalForRequest = NetConfig.idleTimeout
            c.requestCachePolicy = .reloadIgnoringLocalCacheData  // ETag 由我们自己管
            c.urlCache = nil
            c.waitsForConnectivity = false
            self.session = URLSession(configuration: c)
        }
    }

    var currentOrigin: String? { lock.lock(); defer { lock.unlock() }; return service }
    /// 显示封面用：刷新线路期间、刷新失败后仍用最近一次选出过的，已缓存的封面不会变回色块。
    var displayOrigin: String? { lock.lock(); defer { lock.unlock() }; return service ?? lastKnown }

    private func setService(_ v: String?) {
        lock.lock()
        if let v { lastKnown = v }
        let changed = service != v
        service = v
        lock.unlock()
        if changed { DispatchQueue.main.async { self.onOriginChange?() } }
    }

    // MARK: 选线路

    func ensureRoutes() async -> String? {
        if let s = currentOrigin { return s }
        return await resolve()
    }

    func resolve() async -> String? {
        let (t, mine): (Task<String?, Never>, Bool) = lock.withLock {
            if let r = resolving { return (r, false) }
            let t = Task<String?, Never> { await self.doResolve() }
            resolving = t
            return (t, true)
        }
        let v = await t.value
        if mine { lock.withLock { resolving = nil } }
        return v
    }

    private func doResolve() async -> String? {
        let saved = Prefs.d.string(forKey: Prefs.kDomains).flatMap { parseDomains($0) }
        let origins = orderOrigins(
            remembered: Prefs.d.string(forKey: Prefs.kLastService), saved: saved?.domains ?? [], builtin: NetConfig.builtinDomains)
        let won = await pickFirstReachable(origins) { (origin: String) async -> Domains? in
            guard let url = buildUrl(origin, DOMAINS_PATH) else { return nil }
            var req = URLRequest(url: url, timeoutInterval: NetConfig.raceTimeout)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, resp) = try? await self.session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
                data.count <= FileKind.domains.limit
            else { return nil }
            return parseDomains(data)  // 内容必须是格式正确的 domains.json（被劫持返回别的页面也算失败）
        }
        guard let won else { setService(nil); return nil }
        if let data = try? JSONEncoder().encode(won.value), let s = String(data: data, encoding: .utf8) {
            Prefs.d.set(s, forKey: Prefs.kDomains)
        }
        Prefs.d.set(won.origin, forKey: Prefs.kLastService)
        setService(won.origin)
        return won.origin
    }

    /// 手动入口（只有“关于 → 刷新网络线路”用）：忘掉记住的域名，重新选。返回 (选到的域名, 和原来是否同一个)。
    func refreshRoutes() async -> (String?, Bool) {
        let before = Prefs.d.string(forKey: Prefs.kLastService) ?? currentOrigin ?? NetConfig.builtinDomains.first
        setService(nil)
        Prefs.d.removeObject(forKey: Prefs.kLastService)
        let r = await resolve()
        return (r, r != nil && r == before)
    }

    // MARK: 请求

    /// 请求一个相对路径。失败如实返回，不自动换线路、不重试；还没有线路时先选一次。
    func request(_ path: String, etag: String?, maxBytes: Int) async -> NetResult {
        guard let origin = await ensureRoutes() else { return .error("没有可用线路") }
        guard let url = buildUrl(origin, path) else { return .error("地址不对") }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let e = etag { req.setValue(e, forHTTPHeaderField: "If-None-Match") }
        do {
            let (bytes, resp) = try await session.bytes(for: req)
            guard let http = resp as? HTTPURLResponse else { return .error("网络错误") }
            switch http.statusCode {
            case 304: return .notModified
            case 404: return .notFound
            case 200: break
            case 500...: return .error("服务器错误 \(http.statusCode)")
            default: return .error("状态 \(http.statusCode)")
            }
            if http.expectedContentLength > maxBytes { bytes.task.cancel(); return .error("文件过大") }
            var data = Data()
            data.reserveCapacity(max(0, Int(min(http.expectedContentLength, Int64(maxBytes)))))
            var buf = [UInt8](); buf.reserveCapacity(64 * 1024)
            for try await b in bytes {
                buf.append(b)
                if buf.count >= 64 * 1024 { data.append(contentsOf: buf); buf.removeAll(keepingCapacity: true) }
                if data.count + buf.count > maxBytes { bytes.task.cancel(); return .error("文件过大") }
            }
            data.append(contentsOf: buf)
            return .ok(data, etag: http.value(forHTTPHeaderField: "ETag"))
        } catch {
            return .error("网络错误")
        }
    }

    /// 只问一个相对路径的状态码（HEAD）：确认“播放卡住是不是因为文件已被删了”。只用当前线路；拿不到返回 nil。
    func headStatus(_ path: String) async -> Int? {
        guard let origin = currentOrigin, let url = buildUrl(origin, path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: NetConfig.headTimeout)
        req.httpMethod = "HEAD"
        guard let (_, resp) = try? await session.data(for: req) else { return nil }
        return (resp as? HTTPURLResponse)?.statusCode
    }

    func url(for path: String) -> URL? { currentOrigin.flatMap { buildUrl($0, path) } }
}

/// 不等超时再换：从第一个开始试；前一个 1.5 秒还没回应就同时试下一个（前一个不取消）；
/// 前一个明确失败就立刻试下一个。谁先成功用谁，其余取消。全部失败返回 nil。
func pickFirstReachable<T: Sendable>(
    _ origins: [String], staggerMs: UInt64 = NetConfig.raceStaggerMs,
    probe: @escaping @Sendable (String) async -> T?
) async -> (origin: String, value: T)? {
    if origins.isEmpty { return nil }
    return await withTaskGroup(of: (Int, T?).self) { group in
        var next = 0
        var pending = 0
        func start() {
            guard next < origins.count else { return }
            let i = next
            next += 1
            pending += 1
            group.addTask { (i, await probe(origins[i])) }
            if next < origins.count {
                // 计时任务：staggerMs 后返回一个“该开始下一个了”的信号（-1）
                group.addTask {
                    try? await Task.sleep(nanoseconds: staggerMs * 1_000_000)
                    return (-1 - i, nil)
                }
            }
        }
        start()
        var startedAfter = Set<Int>()  // 哪个 i 之后已经开始过下一个（失败和计时都可能触发，只开始一次）
        while let (i, v) = await group.next() {
            if i >= 0 {
                pending -= 1
                if let v { group.cancelAll(); return (origins[i], v) }
                if !startedAfter.contains(i) { startedAfter.insert(i); start() }
                if pending == 0 && next >= origins.count { group.cancelAll(); return nil }
            } else {
                let after = -1 - i
                if !startedAfter.contains(after) { startedAfter.insert(after); start() }
            }
        }
        return nil
    }
}
