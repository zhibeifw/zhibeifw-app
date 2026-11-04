import Foundation

// iOS 的下载：系统的 URLSession 后台会话。
//  · 排队、同时下几个、断网后等网络回来接着下，全由系统做；App 被挂起甚至被系统结束后照样继续；
//  · 暂停用系统的续传数据（cancel(byProducingResumeData:)），继续时交回系统从断点接着下；
//  · 有网就下，不分 Wi-Fi 还是流量；超时等参数用系统默认值。
// App 被系统结束期间发生的事（下完、失败），下次启动时系统交回来；还没人接时先攒着，接上后再交给 DownloadManager。

final class BackgroundDownloader: NSObject, SystemDownloads, URLSessionDownloadDelegate, @unchecked Sendable {
    static let sessionId = "com.zhibeifw.app.downloads"
    static let shared = BackgroundDownloader(files: AppFiles())

    private var session: URLSession!
    private let files: AppFiles
    private let lock = NSLock()
    private var throttles: [Int: ProgressThrottle] = [:]
    private var pending: [DownloadEvent] = []
    private var handler: (@MainActor (DownloadEvent) -> Void)?

    private init(files: AppFiles) {
        self.files = files
        super.init()
        let c = URLSessionConfiguration.background(withIdentifier: Self.sessionId)
        c.sessionSendsLaunchEvents = true
        session = URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }

    func setHandler(_ h: @escaping @MainActor (DownloadEvent) -> Void) {
        let list = lock.withLock { () -> [DownloadEvent] in
            handler = h; defer { pending = [] }; return pending
        }
        Task { @MainActor in list.forEach(h) }
    }

    private func emit(_ e: DownloadEvent) {
        let h = lock.withLock { () -> (@MainActor (DownloadEvent) -> Void)? in
            if handler == nil { pending.append(e) }
            return handler
        }
        guard let h else { return }
        Task { @MainActor in h(e) }
    }

    /// 建任务用的串行队列：按交出的先后建，不占主线程
    private let startQueue = DispatchQueue(label: "dl.start")

    func start(id: String, url: URL, resumeFile: URL) async -> Int? {
        await withCheckedContinuation { c in
            startQueue.async { [session = session!] in
                let resume = try? Data(contentsOf: resumeFile)
                try? FileManager.default.removeItem(at: resumeFile)
                let task = resume.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
                task.taskDescription = id
                task.resume()
                c.resume(returning: task.taskIdentifier)
            }
        }
    }

    func pause(id: String, task tid: Int?) async -> Data? {
        guard let t = await task(id, tid) else { return nil }
        return await withCheckedContinuation { c in t.cancel(byProducingResumeData: { c.resume(returning: $0) }) }
    }

    func cancel(id: String, task tid: Int?) {
        Task { await task(id, tid)?.cancel() }
    }

    /// 同一集有几个任务时取编号最大（最新）的那个
    func activeTasks() async -> [String: Int] {
        var m: [String: Int] = [:]
        for t in await session.allTasks where t.state == .running || t.state == .suspended {
            if let id = t.taskDescription { m[id] = max(m[id] ?? 0, t.taskIdentifier) }
        }
        return m
    }

    /// 知道编号就按编号找；按集 ID 找的话，暂停后马上继续时同一集新旧两个任务都在跑，可能停错
    private func task(_ id: String, _ tid: Int?) async -> URLSessionDownloadTask? {
        let all = await session.allTasks
        if let tid { return all.first { $0.taskIdentifier == tid } as? URLSessionDownloadTask }
        return all.first { $0.taskDescription == id && ($0.state == .running || $0.state == .suspended) } as? URLSessionDownloadTask
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = downloadTask.taskDescription else { return }
        let total = max(0, totalBytesExpectedToWrite)
        // 进度节流：在下载线程上先判断，够 1% 且够 0.25 秒才切到主线程
        let th = lock.withLock { () -> ProgressThrottle in
            if let t = throttles[downloadTask.taskIdentifier] { return t }
            let t = ProgressThrottle(); throttles[downloadTask.taskIdentifier] = t; return t
        }
        if th.pass(written: totalBytesWritten, total: total) {
            emit(.progress(id, totalBytesWritten, total, task: downloadTask.taskIdentifier))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let tid = downloadTask.taskIdentifier
        // 真机上系统的后台下载服务会自己分段取文件，下完报 206 而不是 200；从文件开头起的 206 也是整份文件
        guard let r = downloadTask.response as? HTTPURLResponse,
            isWholeFileResponse(status: r.statusCode, contentRange: r.value(forHTTPHeaderField: "Content-Range"))
        else {
            emit(.failed(id, URLError(.badServerResponse), nil, task: tid)); return
        }
        // location 在这个方法返回后就被删，先挪到我们自己的临时文件（按集命名，见 AppFiles.doneFile）
        let keep = files.doneFile(id)
        try? FileManager.default.removeItem(at: keep)
        do { try FileManager.default.moveItem(at: location, to: keep) } catch {
            emit(.failed(id, isOutOfSpace(error) ? DiskFullError() : error, nil, task: tid)); return
        }
        emit(.finished(id, keep, task: tid))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock { _ = throttles.removeValue(forKey: task.taskIdentifier) }
        guard let id = task.taskDescription, let error else { return }  // 成功的已在 didFinishDownloadingTo 交出
        let ns = error as NSError
        if ns.code == NSURLErrorCannotWriteToFile || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)) {
            emit(.failed(id, DiskFullError(), nil, task: task.taskIdentifier))
        } else {
            emit(.failed(id, error, ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, task: task.taskIdentifier))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            AppDelegate.backgroundCompletion?(); AppDelegate.backgroundCompletion = nil
        }
    }
}
