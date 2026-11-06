import CloudKit
import OSLog
import Foundation

/// iCloud 同步（iPhone、iPad、Apple TV 共用；Android 没有）：收听进度、已听完、最近列表（含删除）、收藏。
///
/// - 用 Apple 的 CKSyncEngine，数据在用户自己的 iCloud 私有数据库里（单独一个分区 UserData），我们看不到。
/// - 两种记录：Progress（每集一条）、Favorite（每门课一条；取消收藏记成 present = 0，不删记录，另一台设备才知道是取消了）。
/// - 以谁为准：每条记录带 modified（本机改动的时刻，毫秒），哪台设备改得晚以哪台为准。
///   modified 记在本机的 cloud_record 表里（同步自己用的表，不动原有的用户表，和 Android 的表结构保持一致）。
/// - 本机一改（Store.onUserChange）：这一条的内容存进“待上传”（UserDefaults，Apple TV 上缓存被清了也不丢），排队上传；
///   什么时候发出由同步引擎安排（会合并），传上去以后从“待上传”里删掉。
/// - iCloud 下来的改动：比本机新才写进本机数据库（Store.applyXxxRecord，不会再当成本机改动传回去），然后刷新页面。
/// - 账户：第一次登录（或重新登录）时，把本机已有的进度和收藏都传上去（iPhone 老用户的历史不丢）；
///   换了账户、退出登录：清掉同步状态，不把上一个账户的数据带进新账户。
/// - 没登录 iCloud、iCloud 空间满了、没网：本机照常工作，同步引擎之后自己补发。
final class CloudSync: CKSyncEngineDelegate, @unchecked Sendable {
    private static let zoneName = "UserData"
    #if DEBUG
    private static let log = Logger(subsystem: "com.zhibeifw.app", category: "CloudSync")
    #endif
    private static let stateKey = "cloud.state"
    private static let outboxKey = "cloud.outbox"

    private let store: Store
    private let zoneID = CKRecordZone.ID(zoneName: CloudSync.zoneName)
    private let defaults = UserDefaults.standard
    private let lock = NSLock()
    private var engine: CKSyncEngine!

    /// iCloud 下来的改动已经写进本机数据库：哪种数据变了（进度、收藏），页面据此重读。
    var onRemoteChange: (@MainActor (_ progress: Bool, _ favorites: Bool) -> Void)?

    init(store: Store, containerIdentifier: String) {
        self.store = store
        try? store.db.exec(
            "CREATE TABLE IF NOT EXISTS cloud_record (name TEXT PRIMARY KEY, modified INTEGER NOT NULL DEFAULT 0, system_fields TEXT)")
        let saved = defaults.data(forKey: Self.stateKey).flatMap {
            try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
        }
        let container = CKContainer(identifier: containerIdentifier)
        var config = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: saved, delegate: self)
        config.automaticallySync = true
        engine = CKSyncEngine(config)
        store.onUserChange = { [weak self] change in self?.noteLocalChange(change) }
    }

    // MARK: 主动同步

    /// 回到前台：主动去取别的设备的改动（只靠 iCloud 推送不稳，Mac 上尤其可能收不到）。
    func fetchNow() {
        Task { try? await engine.fetchChanges() }
    }

    /// 退到后台：马上把还没传的改动传上去，别的设备才能尽快看到。
    func sendNow() {
        Task { try? await engine.sendChanges() }
    }

    // MARK: 记录名、字段

    private func progressName(_ episodeId: String) -> String { "p-" + fileKey(episodeId) }
    private func favoriteName(_ seriesId: String) -> String { "f-" + fileKey(seriesId) }
    private func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }

    private struct Schema { let type: String; let strings: [String]; let doubles: [String]; let ints: [String] }
    private static let progressSchema = Schema(
        type: "Progress", strings: ["episodeId", "seriesId", "seriesTitle", "episodeTitle", "coverPath"],
        doubles: ["position", "duration"], ints: ["completed", "hidden", "lastPlayed", "updated", "modified"])
    private static let favoriteSchema = Schema(
        type: "Favorite", strings: ["seriesId", "seriesTitle", "coverPath"], doubles: [], ints: ["present", "added", "modified"])
    private static func schema(_ type: String) -> Schema? {
        type == progressSchema.type ? progressSchema : type == favoriteSchema.type ? favoriteSchema : nil
    }

    /// 字段都用 UserDefaults 能存的类型：String、NSNumber。"type" 是记录类型。
    private typealias Fields = [String: Any]

    private static func fields(_ p: Store.ProgressRecord, modified: Int64) -> Fields {
        [
            "type": progressSchema.type, "episodeId": p.episodeId, "seriesId": p.seriesId, "seriesTitle": p.seriesTitle,
            "episodeTitle": p.episodeTitle, "coverPath": p.coverPath, "position": p.position, "duration": p.duration,
            "completed": Int64(p.completed ? 1 : 0), "hidden": Int64(p.hidden ? 1 : 0), "lastPlayed": p.lastPlayed,
            "updated": p.updated, "modified": modified,
        ]
    }
    private static func fields(_ f: Store.FavoriteRecord, modified: Int64) -> Fields {
        [
            "type": favoriteSchema.type, "seriesId": f.seriesId, "seriesTitle": f.seriesTitle, "coverPath": f.coverPath,
            "present": Int64(f.present ? 1 : 0), "added": f.added, "modified": modified,
        ]
    }
    private static func str(_ f: Fields, _ k: String) -> String { f[k] as? String ?? "" }
    private static func dbl(_ f: Fields, _ k: String) -> Double { (f[k] as? NSNumber)?.doubleValue ?? 0 }
    private static func int(_ f: Fields, _ k: String) -> Int64 { (f[k] as? NSNumber)?.int64Value ?? 0 }

    private static func fields(of rec: CKRecord) -> Fields? {
        guard let s = schema(rec.recordType) else { return nil }
        var f: Fields = ["type": s.type]
        for k in s.strings { f[k] = rec[k] as? String ?? "" }
        for k in s.doubles { f[k] = (rec[k] as? NSNumber)?.doubleValue ?? 0 }
        for k in s.ints { f[k] = (rec[k] as? NSNumber)?.int64Value ?? 0 }
        return f
    }
    private static func fill(_ rec: CKRecord, _ f: Fields, _ s: Schema) {
        for k in s.strings { rec[k] = str(f, k) as NSString }
        for k in s.doubles { rec[k] = NSNumber(value: dbl(f, k)) }
        for k in s.ints { rec[k] = NSNumber(value: int(f, k)) }
    }

    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: 本机的同步记录（cloud_record）：最后一次改动的时刻、服务器那份的系统字段

    private func localModified(_ name: String) -> Int64? {
        ((try? store.db.first("SELECT modified FROM cloud_record WHERE name = ?", [name])) ?? nil)?.int("modified")
    }
    private func setLocalModified(_ name: String, _ m: Int64) {
        _ = try? store.db.run(
            "INSERT INTO cloud_record (name, modified) VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET modified = excluded.modified", [name, m])
    }
    /// 服务器那份记录的系统字段（变更标记等）：下次改这一条时带上，服务器才认得是同一份、不报冲突
    private func saveSystemFields(_ rec: CKRecord) {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        rec.encodeSystemFields(with: coder)
        coder.finishEncoding()
        _ = try? store.db.run(
            "INSERT INTO cloud_record (name, system_fields) VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET system_fields = excluded.system_fields",
            [rec.recordID.recordName, coder.encodedData.base64EncodedString()])
    }
    private func clearSystemFields(_ name: String) {
        _ = try? store.db.run("UPDATE cloud_record SET system_fields = NULL WHERE name = ?", [name])
    }
    private func newOrKnownRecord(_ id: CKRecord.ID, type: String) -> CKRecord {
        if let b64 = ((try? store.db.first("SELECT system_fields FROM cloud_record WHERE name = ?", [id.recordName])) ?? nil)?.optStr("system_fields"),
            let data = Data(base64Encoded: b64), let coder = try? NSKeyedUnarchiver(forReadingFrom: data)
        {
            coder.requiresSecureCoding = true
            defer { coder.finishDecoding() }
            if let rec = CKRecord(coder: coder), rec.recordType == type { return rec }
        }
        return CKRecord(recordType: type, recordID: id)
    }

    // MARK: 待上传（UserDefaults）

    private func outbox() -> [String: Fields] { defaults.dictionary(forKey: Self.outboxKey) as? [String: Fields] ?? [:] }
    private func updateOutbox(_ body: (inout [String: Fields]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var o = outbox()
        body(&o)
        defaults.set(o, forKey: Self.outboxKey)
    }

    // MARK: 本机改动 → 排队上传

    private func noteLocalChange(_ change: Store.UserChange) {
        let now = Self.now()
        var entries: [(String, Fields)] = []
        switch change {
        case .progress(let ids):
            for id in ids { if let p = store.progressRecord(id) { entries.append((progressName(id), Self.fields(p, modified: now))) } }
        case .favorite(let id):
            entries.append((favoriteName(id), Self.fields(store.favoriteRecord(id), modified: now)))
        }
        enqueue(entries)
        // 收藏、取消收藏是用户点一下的操作：马上上传，别的设备切回来就能看到（系统自己安排的发送时间不固定）。
        // 进度每 5 秒存一次，不这样做：退到后台时上传，平时交给同步引擎安排
        if case .favorite = change { sendNow() }
    }

    private func enqueue(_ entries: [(String, Fields)]) {
        guard !entries.isEmpty else { return }
        #if DEBUG
        for (name, f) in entries {
            Self.log.notice("待上传 \(name, privacy: .public) modified=\(Self.int(f, "modified")) present=\(Self.int(f, "present"))")
        }
        #endif
        for (name, f) in entries { setLocalModified(name, Self.int(f, "modified")) }
        updateOutbox { o in for (name, f) in entries { o[name] = f } }
        engine.state.add(pendingRecordZoneChanges: entries.map { .saveRecord(recordID($0.0)) })
    }

    /// 第一次登录（或重新登录）iCloud：本机已有的进度、收藏都传上去。时刻用数据本身的时间，不用“现在”，
    /// 免得一台很久没用的设备拿旧数据盖掉 iCloud 上更新的
    private func uploadEverything() {
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        var entries: [(String, Fields)] = []
        for id in store.allProgressEpisodeIds() {
            guard let p = store.progressRecord(id) else { continue }
            let name = progressName(id)
            entries.append((name, Self.fields(p, modified: localModified(name) ?? max(p.updated, p.lastPlayed))))
        }
        for id in store.allFavoriteSeriesIds() {
            let f = store.favoriteRecord(id)
            let name = favoriteName(id)
            entries.append((name, Self.fields(f, modified: localModified(name) ?? f.added)))
        }
        enqueue(entries)
    }

    /// 换了账户、退出登录、iCloud 上的数据被删了：清掉同步状态（本机数据留着）
    private func resetCloudState() {
        _ = try? store.db.run("DELETE FROM cloud_record")
        updateOutbox { $0.removeAll() }
    }

    // MARK: iCloud 下来的改动 → 本机

    /// 比本机新（或 force）才写进本机。返回哪种数据变了。
    @discardableResult
    private func applyRemote(_ rec: CKRecord, force: Bool = false) -> (progress: Bool, favorites: Bool) {
        guard let f = Self.fields(of: rec) else { return (false, false) }
        let name = rec.recordID.recordName
        saveSystemFields(rec)
        let remote = Self.int(f, "modified")
        #if DEBUG
        // 开发版的诊断日志：收到的是哪一条、两边的修改时间、收藏的 present，用没用（正式版不编进去）
        let local = localModified(name)
        Self.log.notice(
            "收到 \(name, privacy: .public) remote=\(remote) local=\(local ?? -1) present=\(Self.int(f, "present")) force=\(force) 采用=\(force || remote > (local ?? -1))")
        #endif
        guard force || remote > (localModified(name) ?? -1) else { return (false, false) }
        setLocalModified(name, remote)
        // 本机还没传上去的那份更旧：不要了
        updateOutbox { o in if let mine = o[name], Self.int(mine, "modified") <= remote { o[name] = nil } }
        if rec.recordType == Self.progressSchema.type {
            let p = Store.ProgressRecord(
                episodeId: Self.str(f, "episodeId"), seriesId: Self.str(f, "seriesId"), position: Self.dbl(f, "position"),
                duration: Self.dbl(f, "duration"), completed: Self.int(f, "completed") != 0, hidden: Self.int(f, "hidden") != 0,
                lastPlayed: Self.int(f, "lastPlayed"), updated: Self.int(f, "updated"), seriesTitle: Self.str(f, "seriesTitle"),
                episodeTitle: Self.str(f, "episodeTitle"), coverPath: Self.str(f, "coverPath"))
            guard !p.episodeId.isEmpty else { return (false, false) }
            try? store.applyProgressRecord(p)
            return (true, false)
        } else {
            let fav = Store.FavoriteRecord(
                seriesId: Self.str(f, "seriesId"), present: Self.int(f, "present") != 0, added: Self.int(f, "added"),
                seriesTitle: Self.str(f, "seriesTitle"), coverPath: Self.str(f, "coverPath"))
            guard !fav.seriesId.isEmpty else { return (false, false) }
            try? store.applyFavoriteRecord(fav)
            return (false, true)
        }
    }

    private func notify(_ progress: Bool, _ favorites: Bool) {
        guard progress || favorites else { return }
        Task { @MainActor in self.onRemoteChange?(progress, favorites) }
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let e):
            if let data = try? JSONEncoder().encode(e.stateSerialization) { defaults.set(data, forKey: Self.stateKey) }

        case .accountChange(let e):
            switch e.changeType {
            case .signIn: uploadEverything()
            case .signOut, .switchAccounts: resetCloudState()
            @unknown default: break
            }

        case .fetchedDatabaseChanges(let e):
            // 用户在设置里删了这个 App 的 iCloud 数据：清掉同步状态，不再自动传回去
            if e.deletions.contains(where: { $0.zoneID == zoneID }) { resetCloudState() }

        case .fetchedRecordZoneChanges(let e):
            var p = false, f = false
            for m in e.modifications {
                let r = applyRemote(m.record)
                p = p || r.progress; f = f || r.favorites
            }
            notify(p, f)

        case .sentRecordZoneChanges(let e):
            #if DEBUG
            for rec in e.savedRecords { Self.log.notice("已上传 \(rec.recordID.recordName, privacy: .public)") }
            for x in e.failedRecordSaves {
                Self.log.notice("上传失败 \(x.record.recordID.recordName, privacy: .public) \(x.error.code.rawValue)")
            }
            #endif
            for rec in e.savedRecords {
                saveSystemFields(rec)
                let sent = (rec["modified"] as? NSNumber)?.int64Value ?? 0
                // 发出去以后本机又改了的，留着下次发
                updateOutbox { o in if let mine = o[rec.recordID.recordName], Self.int(mine, "modified") <= sent { o[rec.recordID.recordName] = nil } }
            }
            var p = false, f = false
            for failed in e.failedRecordSaves {
                let id = failed.record.recordID
                switch failed.error.code {
                case .serverRecordChanged:
                    // 别的设备先改了：比时刻，本机新就带上服务器的系统字段重发，服务器新就用服务器的
                    guard let server = failed.error.serverRecord else { break }
                    let theirs = (server["modified"] as? NSNumber)?.int64Value ?? 0
                    let mine = outbox()[id.recordName].map { Self.int($0, "modified") } ?? localModified(id.recordName) ?? 0
                    if mine > theirs {
                        saveSystemFields(server)
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                    } else {
                        let r = applyRemote(server, force: true)
                        p = p || r.progress; f = f || r.favorites
                    }
                case .zoneNotFound:
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                    clearSystemFields(id.recordName)
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                case .unknownItem:
                    clearSystemFields(id.recordName)
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                default:
                    // 没网、iCloud 空间满了、请求太频繁等：同步引擎之后自己重试；内容还在“待上传”里
                    NSLog("iCloud 同步：上传 \(id.recordName) 失败：\(failed.error)")
                }
            }
            notify(p, f)

        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async
        -> CKSyncEngine.RecordZoneChangeBatch?
    {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] id in
            // 已经发过、或者这一条已经不存在：从同步引擎的待办里移掉（照 Apple 示例），免得它反复空跑
            guard let rec = self?.recordToSend(id) else {
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
                return nil
            }
            return rec
        }
    }

    /// 要发的这一条：用“待上传”里存的内容；没有了（已经发过、或者这一条已经不存在）返回 nil，同步引擎就跳过它
    private func recordToSend(_ id: CKRecord.ID) -> CKRecord? {
        guard let f = outbox()[id.recordName], let type = f["type"] as? String, let s = Self.schema(type) else { return nil }
        let rec = newOrKnownRecord(id, type: type)
        Self.fill(rec, f, s)
        return rec
    }
}
