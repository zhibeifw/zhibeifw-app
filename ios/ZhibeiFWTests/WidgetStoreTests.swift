import XCTest
@testable import ZhibeiFW

final class WidgetStoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func playing(_ id: String = "e", _ playing: Bool = true) -> WidgetNowPlaying {
        WidgetNowPlaying(
            item: WidgetItem(seriesId: "s", seriesTitle: "课程", episodeId: id, color: 0),
            position: 30, duration: 600, playing: playing, loaded: true)
    }
    func testCatalogCommitKeepsNewerPauseAndEpisode() throws {
        let file = directory.appendingPathComponent("snapshot.json")
        for next in [playing("e", false), playing("next")] {
            let old = WidgetSnapshot(nowPlaying: playing(), catalogCheckedAt: 10)
            WidgetStore.update(at: file) { $0 = old }
            WidgetStore.update(at: file) { $0.nowPlaying = next }
            let item = WidgetItem(seriesId: "latest", seriesTitle: "新课", episodeId: "new", color: 0)
            WidgetStore.update(at: file) { $0.mergeCatalog([item], checkedAt: 20) }
            let saved = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(contentsOf: file))
            XCTAssertEqual(saved.nowPlaying, next)
            XCTAssertEqual(saved.latest, [item])
        }
    }
    func testSlowAppWriteCannotReplaceQuickPlaybackOrNewerCatalog() throws {
        let file = directory.appendingPathComponent("snapshot.json")
        let original = WidgetSnapshot(nowPlaying: playing(), catalogCheckedAt: 10)
        WidgetStore.update(at: file) { $0 = original }
        WidgetStore.update(at: file) {
            $0.nowPlaying = self.playing("next", false)
            $0.mergeCatalog([WidgetItem(seriesId: "new", seriesTitle: "新课", color: 0)], checkedAt: 30)
        }
        WidgetStore.update(at: file) { $0.mergeApp(original, basedOn: original) }
        let result = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(contentsOf: file))
        XCTAssertEqual(result.nowPlaying, playing("next", false))
        XCTAssertEqual(result.latest.first?.seriesId, "new")
    }
    func testObsoleteCoverWorkKeepsTheNewCurrentCover() throws {
        let file = directory.appendingPathComponent("snapshot.json")
        var first = playing(); first.item.cover = "old.jpg"
        let original = WidgetSnapshot(nowPlaying: first)
        WidgetStore.update(at: file, covers: ["old.jpg": Data([1])]) { $0 = original }
        var next = playing("next"); next.item.cover = "new.jpg"
        WidgetStore.update(at: file, covers: ["new.jpg": Data([2])]) { $0.nowPlaying = next }
        WidgetStore.update(at: file, covers: ["old.jpg": Data([1])]) { $0.mergeApp(original, basedOn: original) }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("covers/new.jpg")), Data([2]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("covers/old.jpg").path))
    }

    func testConcurrentUpdatesDoNotLoseOtherFields() throws {
        let file = directory.appendingPathComponent("snapshot.json")
        DispatchQueue.concurrentPerform(iterations: 40) { _ in
            WidgetStore.update(at: file) { $0.catalogCheckedAt = ($0.catalogCheckedAt ?? 0) + 1 }
        }
        let result = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(contentsOf: file))
        XCTAssertEqual(result.catalogCheckedAt, 40)
    }
    func testMissingCatalogIsFailureButInvalidRemainsSilent() {
        XCTAssertTrue(SyncSummary(index: .missing).failed)
        XCTAssertTrue(SyncSummary(index: .failed).failed)
        for status in [FileStatus.invalid, .updated, .unchanged] {
            XCTAssertFalse(SyncSummary(index: status).failed)
        }
    }
}
