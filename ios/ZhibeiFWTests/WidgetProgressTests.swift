import XCTest
@testable import ZhibeiFW

final class WidgetProgressTests: XCTestCase {
    func testExistingSnapshotWithoutProgressStillDecodes() throws {
        let data = Data(#"{"latest":[{"seriesId":"s","seriesTitle":"课","episodeId":"e","color":4294967295}]}"#.utf8)
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        XCTAssertNil(snapshot.latest.first?.progress)
    }

    func testLatestProgressSurvivesSnapshotRoundTrip() throws {
        let item = WidgetItem(seriesId: "s", seriesTitle: "课", episodeId: "e", cover: nil, color: 0, progress: 0.4)
        let snapshot = WidgetSnapshot(latest: [item])
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(WidgetSnapshot.self, from: data).latest.first?.progress, 0.4)
    }
    func testLoadingKeepsSavedProgress() {
        let value = widgetPlaybackProgress(position: 0, duration: 0, positionKnown: false,
                                           savedPosition: 180, savedDuration: 600, completed: false)
        XCTAssertEqual(value.position, 180)
        XCTAssertEqual(value.duration, 600)
    }

    func testKnownPositionIncludingZeroWinsOverSavedProgress() {
        let value = widgetPlaybackProgress(position: 0, duration: 600, positionKnown: true,
                                           savedPosition: 180, savedDuration: 600, completed: false)
        XCTAssertEqual(value.position, 0)
        XCTAssertEqual(value.duration, 600)
    }

    func testNewEpisodeDoesNotInheritPreviousProgress() {
        let value = widgetPlaybackProgress(position: 180, duration: 600, positionKnown: false,
                                           savedPosition: nil, savedDuration: nil, completed: false)
        XCTAssertEqual(value.position, 0)
        XCTAssertEqual(value.duration, 0)
    }

    func testCompletedEpisodeRestartsAtBeginning() {
        let value = widgetPlaybackProgress(position: 0, duration: 0, positionKnown: false,
                                           savedPosition: 600, savedDuration: 600, completed: true)
        XCTAssertEqual(value.position, 0)
        XCTAssertEqual(value.duration, 600)
    }
}
