import Foundation

/// App 的文件位置，和 v1.0 完全一样，覆盖安装后直接接着用。
struct AppFiles: Sendable {
    let documents: URL
    let caches: URL

    init(documents: URL? = nil, caches: URL? = nil) {
        let fm = FileManager.default
        self.documents = documents ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.caches = caches ?? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    var dbDir: URL { documents.appendingPathComponent("SQLite", isDirectory: true) }
    var dbPath: URL { dbDir.appendingPathComponent("zhibeifw.db") }
    var v1KVPath: URL { dbDir.appendingPathComponent("ExpoSQLiteStorage") }
    var audioDir: URL { documents.appendingPathComponent("audio", isDirectory: true) }
    var coversDir: URL { documents.appendingPathComponent("covers", isDirectory: true) }
    var partDir: URL { caches.appendingPathComponent("dl-part", isDirectory: true) }
    var backupPath: URL { documents.appendingPathComponent("backup", isDirectory: true).appendingPathComponent("user-before-migrate.db") }

    func prepare() {
        let fm = FileManager.default
        for d in [dbDir, audioDir, coversDir, partDir, backupPath.deletingLastPathComponent()] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        // 已下载的音频不进 iCloud 备份
        var u = audioDir
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
    }

    func partFile(_ episodeId: String) -> URL { partDir.appendingPathComponent(fileKey(episodeId) + ".part") }
    func resumeDataFile(_ episodeId: String) -> URL { partDir.appendingPathComponent(fileKey(episodeId) + ".resume") }
    /// 系统下完、还没移入资料库的文件：按集命名，App 来不及处理就被关掉时，下次对账还认得出
    func doneFile(_ episodeId: String) -> URL { partDir.appendingPathComponent(fileKey(episodeId) + ".done") }
    func coverFile(seriesId: String) -> URL { coversDir.appendingPathComponent(fileKey(seriesId) + ".jpg") }

    /// 下载完成后的本地文件（相对 App 文件目录，如 audio/h_xxx.mp3），数据库里存相对路径。
    func finalRelative(_ episodeId: String, audioPath: String) -> String {
        let ext = (audioPath as NSString).pathExtension.lowercased()
        let safeExt = ext.range(of: "^[a-z0-9]{1,5}$", options: .regularExpression) != nil ? ext : "mp3"
        return "audio/" + fileKey(episodeId) + "." + safeExt
    }
    func absolute(_ relative: String) -> URL { documents.appendingPathComponent(relative) }

    enum LocalAudio { case none, file(URL), missing }

    /// 这一集已下载的本地文件：文件真的在才返回；记录在但文件丢了返回 .missing。
    func localAudio(for episodeId: String, store: Store) -> LocalAudio {
        guard let r = store.getDownload(episodeId), r.state == .done, let lf = r.localFile else { return .none }
        let u = absolute(lf)
        return FileManager.default.fileExists(atPath: u.path) ? .file(u) : .missing
    }
}
