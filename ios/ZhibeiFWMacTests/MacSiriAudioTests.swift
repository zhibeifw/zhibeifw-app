import XCTest
import MediaIntents
@testable import ZhibeiFWMac

@available(macOS 27.0, *)
final class MacSiriAudioTests: XCTestCase {
    private func makeStore() throws -> Store {
        let db = try SQLiteDB(path: ":memory:")
        _ = try Migrator.migrate(db)
        let store = Store(db: db)
        try store.replaceIndex(
            IndexFile(
                categories: [CategoryEntry(id: "c", name: "分类", icon: nil, color: nil)],
                series: [
                    SeriesEntry(
                        id: "s", title: "论语", categoryId: "c", coverPath: "cover.jpg", status: "ongoing",
                        description: nil,
                        episodes: [
                            EpisodeEntry(id: "e1", title: "导言", audioPath: "1.mp3", duration: 600),
                            EpisodeEntry(id: "e10", title: "第10课", audioPath: "10.mp3", duration: 600),
                        ], updatedAt: nil)
                ], featured: []))
        return store
    }

    func testCourseWithoutEpisodeReturnsCourseAndNoAutomaticEpisode() throws {
        let store = try makeStore()
        let input = AudioSearch(criteria: .searchQuery("论语"))
        XCTAssertEqual(try MacSiriAudio.courses(input, store: store).map(\.id), ["s"])
        XCTAssertTrue(try MacSiriAudio.episodes(input, store: store, currentID: nil).isEmpty)
    }

    func testEpisodeNumberIsTitleNotPositionAndMissingDoesNotFallback() throws {
        let store = try makeStore()
        let input = AudioSearch(criteria: .searchQuery("论语第十集"))
        XCTAssertEqual(try MacSiriAudio.episodes(input, store: store, currentID: nil).map(\.id), ["e10"])
        XCTAssertTrue(try MacSiriAudio.courses(input, store: store).isEmpty)
        for text in ["论语第2课", "论语第999集", "另一门课第十集"] {
            let missing = AudioSearch(criteria: .searchQuery(text))
            XCTAssertTrue(try MacSiriAudio.episodes(missing, store: store, currentID: nil).isEmpty)
            XCTAssertTrue(try MacSiriAudio.courses(missing, store: store).isEmpty)
        }
    }

    func testResumeUsesCurrentThenRecentUnfinishedAndNeverChoosesFirst() throws {
        let store = try makeStore()
        let input = AudioSearch(criteria: .unspecified)
        XCTAssertTrue(try MacSiriAudio.episodes(input, store: store, currentID: nil).isEmpty)
        try store.recordPlayback(episodeId: "e10", seriesId: "s", position: 100, duration: 600)
        XCTAssertEqual(try MacSiriAudio.episodes(input, store: store, currentID: nil).map(\.id), ["resume:e10"])
        XCTAssertEqual(try MacSiriAudio.episodes(input, store: store, currentID: "e1").map(\.id), ["resume:e1"])
        try store.markCompleted("e10", seriesId: "s", completed: true)
        XCTAssertTrue(try MacSiriAudio.episodes(input, store: store, currentID: nil).isEmpty)
    }

    func testURLOnlyResolvesExistingAppCourseLinks() throws {
        let store = try makeStore()
        let input = AudioSearch(
            criteria: .url([
                WidgetLink.series("s").url, WidgetLink.series("missing").url,
                URL(string: "https://example.com/audio.mp3")!,
            ]))
        XCTAssertEqual(try MacSiriAudio.courses(input, store: store).map(\.id), ["s"])
        XCTAssertTrue(try MacSiriAudio.episodes(input, store: store, currentID: nil).isEmpty)
    }
    func testEmptySearchDoesNotSelectAnyCourse() throws {
        let store = try makeStore()
        let input = AudioSearch(criteria: .searchQuery("   "))
        XCTAssertTrue(try MacSiriAudio.courses(input, store: store).isEmpty)
        XCTAssertTrue(try MacSiriAudio.episodes(input, store: store, currentID: nil).isEmpty)
    }

    @MainActor
    func testUnsupportedQueueRequestDoesNotStartPlayback() async throws {
        var intent = MacSiriPlayAudioIntent()
        intent.playbackAttributes = []
        intent.queueLocation = .next
        do {
            _ = try await intent.perform()
            XCTFail("不能把加入队列请求改成立即播放")
        } catch MacSiriAudioError.unsupportedPlaybackMode {}
    }

    func testResumeEntityCanBeResolvedWithoutLosingPlaybackContext() throws {
        let store = try makeStore()
        let entity = try XCTUnwrap(MacSiriAudio.episode("resume:e10", store: store))
        XCTAssertEqual(entity.id, "resume:e10")
        XCTAssertEqual(MacSiriAudio.episodeID(entity.id), "e10")
        XCTAssertEqual(entity.show?.id, "s")
        XCTAssertNil(try MacSiriAudio.episode("resume:missing", store: store))
    }

}
