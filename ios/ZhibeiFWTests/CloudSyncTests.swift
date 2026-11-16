import CloudKit
import XCTest
@testable import ZhibeiFW

final class CloudSyncTests: XCTestCase {
    private var db: SQLiteDB!
    private var store: Store!
    private var defaults: UserDefaults!
    private var suite: String!
    private var sync: CloudSync!
    override func setUpWithError() throws {
        db = try SQLiteDB(path: ":memory:")
        _ = try Migrator.migrate(db)
        store = Store(db: db)
        suite = "CloudSyncTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        sync = makeSync()
    }
    override func tearDownWithError() throws {
        sync = nil; store = nil; db = nil
        defaults.removePersistentDomain(forName: suite)
    }
    private func makeSync() -> CloudSync {
        CloudSync(store: store, containerIdentifier: "iCloud.com.zhibeifw.app", defaults: defaults, automaticallySync: false)
    }
    private func record(_ type: String) -> CKRecord {
        let record = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: "test-record"))
        record["seriesId"] = "s" as NSString
        record["episodeId"] = "e" as NSString
        record["modified"] = NSNumber(value: 20)
        record["position"] = NSNumber(value: 306)
        record["duration"] = NSNumber(value: 3600)
        record["present"] = NSNumber(value: 1)
        return record
    }
    func testFailedProgressKeepsVersionAndOutboxAndReplaysAfterRestart() throws {
        defaults.set(["test-record": ["modified": 10]], forKey: "cloud.outbox")
        try db.exec("CREATE TRIGGER reject_progress BEFORE INSERT ON user_progress BEGIN SELECT RAISE(FAIL, 'test'); END")
        let result = sync.applyRemote(record("Progress"))
        XCTAssertFalse(result.progress)
        XCTAssertNil(store.loadProgress("e"))
        XCTAssertNil(try db.first("SELECT modified FROM cloud_record WHERE name = 'test-record'"))
        XCTAssertNotNil(defaults.dictionary(forKey: "cloud.outbox")?["test-record"])
        try db.exec("DROP TRIGGER reject_progress")
        sync = makeSync()
        XCTAssertEqual(store.loadProgress("e")?.position, 306)
        XCTAssertEqual(try db.first("SELECT modified FROM cloud_record WHERE name = 'test-record'")?.int("modified"), 20)
        XCTAssertNil(defaults.dictionary(forKey: "cloud.outbox")?["test-record"])
    }
    func testFailedFavoriteDeletionIsRetried() throws {
        store.onUserChange = nil
        try store.addFavorite("s")
        try db.exec("CREATE TRIGGER reject_favorite BEFORE DELETE ON user_favorite BEGIN SELECT RAISE(FAIL, 'test'); END")
        let rec = record("Favorite"); rec["present"] = NSNumber(value: 0)
        XCTAssertFalse(sync.applyRemote(rec).favorites)
        XCTAssertTrue(store.isFavorite("s"))
        try db.exec("DROP TRIGGER reject_favorite")
        sync.retryPendingRemoteChanges()
        XCTAssertFalse(store.isFavorite("s"))
    }
    func testVersionWriteFailureRollsBackBusinessRecord() throws {
        try db.exec("CREATE TRIGGER reject_metadata BEFORE INSERT ON cloud_record BEGIN SELECT RAISE(FAIL, 'test'); END")
        XCTAssertFalse(sync.applyRemote(record("Favorite")).favorites)
        XCTAssertFalse(store.isFavorite("s"))
        try db.exec("DROP TRIGGER reject_metadata")
        sync.retryPendingRemoteChanges()
        XCTAssertTrue(store.isFavorite("s"))
    }
    func testPendingRemoteCannotOverwriteNewerLocalChange() throws {
        try db.exec("CREATE TRIGGER reject_progress BEFORE INSERT ON user_progress BEGIN SELECT RAISE(FAIL, 'test'); END")
        _ = sync.applyRemote(record("Progress"))
        try db.exec("DROP TRIGGER reject_progress")
        store.onUserChange = nil
        try store.recordPlayback(episodeId: "e", seriesId: "s", position: 500, duration: 3600)
        try db.run("INSERT INTO cloud_record(name, modified) VALUES ('test-record', 30)")
        sync.retryPendingRemoteChanges()
        XCTAssertEqual(store.loadProgress("e")?.position, 500)
    }
}
