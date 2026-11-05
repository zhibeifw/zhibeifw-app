import SwiftUI
import ImageIO
import CryptoKit

// 封面图加载（“封面图”：自己写，不用 SDWebImage）。
// 按相对路径作缓存键（换域名不失效）；内存缓存 NSCache（按解码后字节数限额）+ 磁盘缓存（系统缓存目录，可被系统清掉，不设上限）；
// 网络走 Network 模块的当前线路；解码用 CGImageSource 降采样到显示尺寸；视图消失时取消请求。
// ：列表里的小图先下发布脚本生成的 320 / 640 小图（coverSourcePath），服务器上没有就改用原图。
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private let memory = NSCache<NSString, PlatformImage>()
    let diskDir: URL
    private let session: URLSession
    private var inflight: [String: Task<Fetch, Never>] = [:]
    enum Fetch { case ok, notFound, failed }
    /// 每张图（按原图路径）在内存里解码过的最大一份：换尺寸时先拿它顶上，不闪色块。
    private var largest: [String: (key: NSString, width: Int)] = [:]
    /// 服务器上没有小图的封面（老课程、漏传）：本次运行里直接用原图，不再白请求。
    private var noThumbs: Set<String> = []
    /// 小图请求的结果计数：开头连续 3 张都“不存在”、一张都没成功，就认为服务器还没传小图，这次运行里全部直接用原图
    private var thumbHits = 0, thumbMisses = 0
    private var thumbsOff: Bool { thumbHits == 0 && thumbMisses >= 3 }
    private let lock = NSLock()

    init(diskDir: URL? = nil) {
        self.diskDir =
            diskDir
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(
                "covers-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.diskDir, withIntermediateDirectories: true)
        memory.totalCostLimit = 48 * 1024 * 1024
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = NetConfig.idleTimeout
        c.urlCache = nil
        session = URLSession(configuration: c)
    }

    /// 缓存键：相对路径的 SHA-256（文件名安全、定长）。
    static func diskName(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 这个显示宽度该用哪个文件（小图 / 原图）
    private func source(_ path: String, _ requested: Int) -> String {
        lock.withLock { thumbsOff || noThumbs.contains(path) } ? path : coverSourcePath(path, requestedPx: requested)
    }

    private func memKey(_ src: String, _ px: Int) -> NSString { "\(src)#\(px)" as NSString }
    private func diskFile(_ src: String) -> URL { diskDir.appendingPathComponent(Self.diskName(src)) }

    /// 内存里这个尺寸的图；有本地封面时 load 按原图路径存，这里也先按它找
    func cached(_ path: String, maxPixel: Int, local: Bool = false) -> PlatformImage? {
        let px = coverBucket(maxPixel)
        if local, let m = memory.object(forKey: memKey(path, px)) { return m }
        return memory.object(forKey: memKey(source(path, maxPixel), px))
    }

    /// 这张图在内存里已有的任一尺寸（取最大的）：正确尺寸还在解码时先用它显示。
    func anyCached(_ path: String) -> PlatformImage? {
        guard let k = lock.withLock({ largest[path]?.key }) else { return nil }
        return memory.object(forKey: k)
    }

    /// 取图：内存 → 本地文件（资料库离线封面）→ 磁盘 → 网络。
    func load(_ path: String, maxPixel requested: Int, localFile: URL? = nil) async -> PlatformImage? {
        let px = coverBucket(requested)
        if let lf = localFile, FileManager.default.fileExists(atPath: lf.path) {
            let key = memKey(path, px)
            if let m = memory.object(forKey: key) { return m }
            if let img = Self.downsample(lf, maxPixel: px) { store(img, key, path); return img }
        }
        if path.hasPrefix("local:") { return nil }  // 只有本地封面的键：本地文件没了就没有，不去网上取
        if let m = memory.object(forKey: memKey(source(path, requested), px)) { return m }
        // 用它确保在磁盘上的那个文件（小图不存在时是原图），不再算一次：中间开关可能被别的线程改了
        guard let src = await ensureOnDisk(path, requested), !Task.isCancelled else { return nil }
        guard let img = Self.downsample(diskFile(src), maxPixel: px) else {
            try? FileManager.default.removeItem(at: diskFile(src)); return nil
        }
        store(img, memKey(src, px), path)
        return img
    }

    /// 保证这个尺寸要用的文件在磁盘上（小图没有就下原图），返回那个文件的路径；取不到返回 nil。预先下载也用它。
    @discardableResult
    func ensureOnDisk(_ path: String, _ requested: Int) async -> String? {
        let src = source(path, requested)
        if FileManager.default.fileExists(atPath: diskFile(src).path) {
            // 缓存里的小图同样说明服务器有小图：不算的话，第二次启动后碰到几门缺小图的课就会全部改用原图
            if src != path { lock.withLock { thumbHits += 1 } }
            return src
        }
        let r = await fetch(src)
        if src != path { lock.withLock { if r == .ok { thumbHits += 1 } else if r == .notFound { thumbMisses += 1 } } }
        if r == .ok { return src }
        // 只有服务器明确说“没有这张小图”（404）才改用原图；网络失败不算
        guard src != path, r == .notFound else { return nil }
        lock.withLock { _ = noThumbs.insert(path) }
        if FileManager.default.fileExists(atPath: diskFile(path).path) { return path }
        return await fetch(path) == .ok ? path : nil
    }

    /// 原图在磁盘缓存里的文件（没有就先下载）；取不到返回 nil。
    func originalFile(_ path: String) async -> URL? {
        guard let src = await ensureOnDisk(path, Int.max) else { return nil }
        let f = diskFile(src)
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    /// 下载一个文件到磁盘缓存；同一个文件并发只下一次。下载本身不随某个视图取消（别的视图可能也在等它）。
    private func fetch(_ src: String) async -> Fetch {
        let file = diskFile(src)
        let task: Task<Fetch, Never> = lock.withLock {
            if let t = inflight[src] { return t }
            let t = Task { [session] () -> Fetch in
                guard let url = await Network.shared.ensureRoutes().flatMap({ buildUrl($0, src) }) else { return .failed }
                guard let (tmp, resp) = try? await session.download(from: url) else { return .failed }
                // 异步下载交回的临时文件系统不会自己删：没挪走的都删掉
                defer { try? FileManager.default.removeItem(at: tmp) }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 404 || code == 403 { return .notFound }  // R2 公开桶不存在的文件回 404（个别配置回 403）
                guard code == 200 else { return .failed }
                guard let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= FileKind.cover.limit else {
                    return .failed
                }
                // rename(2) 覆盖旧文件是原子的：不会有“旧的删了、新的还没到”的一瞬间让读文件的地方扑空
                // 缓存目录可能被系统清理空间时整个删掉：没有就重建，否则以后每张都失败
                if rename(tmp.path, file.path) != 0 {
                    guard errno == ENOENT else { return .failed }
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard rename(tmp.path, file.path) == 0 else { return .failed }
                }
                return .ok
            }
            inflight[src] = t
            return t
        }
        let ok = await task.value
        // 只清自己等的这一个：别的调用可能已经为同一个文件起了新的下载
        lock.withLock { if inflight[src] == task { inflight[src] = nil } }
        return ok
    }

    /// 预先下载（只存磁盘、不解码），最多同时 3 张：主页刷新后把主页上的封面先下好。
    func prefetch(_ items: [(path: String, requested: Int)]) {
        let list = items.filter { !$0.path.isEmpty }
        guard !list.isEmpty else { return }
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { g in
                var it = list.makeIterator()
                for _ in 0..<3 { if let x = it.next() { g.addTask { _ = await self.ensureOnDisk(x.path, x.requested) } } }
                while await g.next() != nil { if let x = it.next() { g.addTask { _ = await self.ensureOnDisk(x.path, x.requested) } } }
            }
        }
    }

    private func store(_ img: PlatformImage, _ key: NSString, _ path: String) {
        let cost = Int(img.size.width * img.size.height * img.scale * img.scale * 4)
        memory.setObject(img, forKey: key, cost: cost)
        let w = Int(max(img.size.width, img.size.height) * img.scale)
        lock.withLock { if w > (largest[path]?.width ?? 0) { largest[path] = (key, w) } }
    }

    static func downsample(_ url: URL, maxPixel: Int) -> PlatformImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return PlatformImage(cgImage: cg)
    }

    /// 关于页“清除缓存”：清内存和磁盘两层（不碰已下载课程另存的封面）。
    func clear() throws {
        memory.removeAllObjects()
        lock.withLock {
            largest.removeAll(); noThumbs.removeAll(); thumbHits = 0; thumbMisses = 0
        }
        let fm = FileManager.default
        // 磁盘缓存不设上限，可能有几千个文件：先改名（一下就完），旧目录放到后台删，不卡界面
        if fm.fileExists(atPath: diskDir.path) {
            let trash = diskDir.deletingLastPathComponent().appendingPathComponent("covers-cache-trash-\(UUID().uuidString)")
            try fm.moveItem(at: diskDir, to: trash)
            DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: trash) }
        }
        try fm.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }
}

/// 封面视图：16:9 等比例由调用方定。加载中是淡灰底，图到了淡入；没有封面或加载失败时显示内容色块。
struct CoverImage: View {
    let path: String
    let colorId: String
    var radius: CGFloat
    var localFile: URL? = nil
    @State private var image: PlatformImage?
    @State private var failed = false
    @Environment(\.displayScale) private var scale
    /// 取图和缓存用的键。已下架的课目录里没有封面路径，但下载时存过本地封面：用“local:课程 ID”当键，
    /// 否则几门这样的课都用空字符串当键，会互相串图
    private var key: String { path.isEmpty && localFile != nil ? "local:\(colorId)" : path }
    @ObservedObject private var origin = OriginWatcher.shared

    var body: some View {
        // 正确尺寸还没解码好时，先用内存里这张图的任一尺寸顶上（播放页弹出、换尺寸时不闪色块）
        let shown = image ?? (key.isEmpty ? nil : ImageLoader.shared.anyCached(key))
        // 没有封面、或确实取不到：内容色块；还在加载：淡灰底（不像色块那样显眼）
        let placeholder = key.isEmpty || failed ? placeholderColor(colorId).color : C.backgroundSecondary
        Rectangle().fill(placeholder)
            // 图片铺满容器、跟着容器走（不用上一帧量到的尺寸，动画中不会错位露出色块）
            .overlay {
                if let shown { Image(platformImage: shown).resizable().scaledToFill().transition(.opacity) }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onGeometryChange(for: Int.self) {
                coverRequestPx(Int($0.size.width * scale))
            } action: { px in
                if image.map({ Int(max($0.size.width, $0.size.height) * $0.scale) < px }) ?? true { load(px) }
            }
            // 换了一门课（比如播放胶囊换到另一门课）：清掉旧图后要马上取新图，尺寸没变不会再触发上面的尺寸回调
            .onChange(of: key) { _, _ in
                image = nil; failed = false; task?.cancel(); if lastPx > 0 { load(nil) }
            }
            .onChange(of: origin.version) { _, _ in if image == nil { load(nil) } }
            // 进了别的页面再回来：消失时取消了的请求要重新开始，否则会一直停在占位色
            .onAppear { if image == nil && lastPx > 0 { load(nil) } }
            // 不在消失时取消：播放胶囊在打开播放页、标签栏收起时会短暂消失又出现，取消了可能就停在占位色（真机上清除缓存后才恢复）。
            // 下载本来就不随视图取消，省下的只是一次解码，不值得
            .accessibilityHidden(true)
    }

    @State private var task: Task<Void, Never>?
    @State private var lastPx = 0

    private func load(_ px: Int?) {
        let px = px ?? lastPx
        // 没有封面路径但有本地封面（已下架、已下载的课）也要取
        guard !key.isEmpty, px > 0 else { return }
        lastPx = px
        if let c = ImageLoader.shared.cached(key, maxPixel: px, local: localFile != nil) { image = c; failed = false; return }
        task?.cancel()
        let p = key, lf = localFile
        task = Task {
            let img = await ImageLoader.shared.load(p, maxPixel: px, localFile: lf)
            // 换了课时 onChange(of: path) 会取消这个任务
            guard !Task.isCancelled else { return }
            if let img {
                failed = false
                withAnimation(.easeOut(duration: Double(Tok.Motion.fadeMs) / 1000)) { image = img }
            } else if image == nil {
                failed = true
            }
        }
    }
}

/// 选出域名、刷新线路后，已显示为色块的封面重新取图。
@MainActor
final class OriginWatcher: ObservableObject {
    static let shared = OriginWatcher()
    @Published var version = 0
    private init() {}
    func bump() { version += 1 }
}
