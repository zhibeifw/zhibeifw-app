import XCTest
import Foundation
@testable import ZhibeiFW

final class SiriControlsTests: XCTestCase {
    func testErrorsProvideSiriReadableReasons() {
        let errors: [any Error & CustomLocalizedStringResourceConvertible] = [
            SiriControlError.noCurrent, SiriControlError.offline,
            SiriControlError.saveFailed, SiriControlError.invalidOption,
            SiriPlaybackError.notReady, SiriPlaybackError.noRecent,
            SiriPlaybackError.unavailable, SiriPlaybackError.failed
        ]
        for error in errors {
            XCTAssertFalse(String(localized: error.localizedStringResource).isEmpty)
        }
        XCTAssertEqual(String(localized: SiriControlError.noCurrent.localizedStringResource),
                       "当前没有正在收听的课程，请先播放一集。")
    }

    func testRateOptionsMatchApp() {
        XCTAssertEqual(Set(SiriRate.allCases.map(\.value)), Set(PLAYBACK_RATES))
    }
    func testSleepOptionsUseExistingChoices() throws {
        XCTAssertEqual(Set(SiriSleep.allCases.map(\.rawValue)), Set(SLEEP_CHOICES.filter { $0.id != "off" }.map(\.id)))
        XCTAssertEqual(try SiriSleep.thirty.setting(now: 100), .timer(deadline: 1900, minutes: 30))
        XCTAssertEqual(try SiriSleep.end.setting(now: 100), .end)
    }
    @MainActor
    func testRepeatedFavoriteNeverRemovesFavorite() throws {
        let db = try SQLiteDB(path: ":memory:")
        _ = try Migrator.migrate(db)
        let store = Store(db: db)
        let info = EpisodeInfo(episodeId: "e", seriesId: "s", seriesTitle: "课", episodeTitle: "第1课", coverPath: "", audioPath: "a.mp3", pos: 1)
        try SiriControls.favorite(info, store: store)
        try SiriControls.favorite(info, store: store)
        XCTAssertTrue(store.isFavorite("s"))
        XCTAssertEqual(try store.loadFavorites().count, 1)
    }
}
