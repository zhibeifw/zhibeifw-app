import XCTest
@testable import ZhibeiFW

@MainActor
final class UpgradeCheckerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let now = 200_000_000.0
    private let outdatedBody = #"{"latestVersion":"2026.12.01","minVersion":"2026.11.14","apkPath":"releases/app.apk"}"#

    override func setUp() async throws {
        suite = "UpgradeCheckerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testMinimumVersionAndDismissal() async {
        let checker = makeChecker { _ in .ok(Data(self.outdatedBody.utf8), etag: "v1") }
        await checker.check(manual: false)
        XCTAssertTrue(checker.outdated)
        XCTAssertEqual(defaults.string(forKey: Prefs.kUpdateEtag), "v1")
        XCTAssertEqual(defaults.double(forKey: Prefs.kUpdateChecked), now)
        XCTAssertTrue(checker.showsNotice)
        checker.outdatedDismissed = true
        XCTAssertFalse(checker.showsNotice)
        await checker.check(manual: true)
        XCTAssertTrue(checker.outdatedDismissed)
        XCTAssertFalse(makeChecker { _ in .notModified }.outdatedDismissed)
    }

    func testSupportedVersionDoesNotAdvertiseOrdinaryUpdates() async {
        let body = #"{"latestVersion":"2026.12.01","minVersion":"2026.11.13","apkPath":"releases/app.apk"}"#
        let checker = makeChecker { _ in .ok(Data(body.utf8), etag: nil) }
        await checker.check(manual: false)
        XCTAssertFalse(checker.outdated)
    }

    func testWithin24HoursUsesSavedResultWithoutRequest() async {
        defaults.set(outdatedBody, forKey: Prefs.kUpdateBody)
        defaults.set(now - 1000, forKey: Prefs.kUpdateChecked)
        let checker = makeChecker { _ in
            XCTFail("不应重复请求"); return .error("unexpected")
        }
        await checker.check(manual: false)
        XCTAssertTrue(checker.outdated)
    }

    func testNotModifiedReusesBodyAndSendsETag() async {
        defaults.set(outdatedBody, forKey: Prefs.kUpdateBody)
        defaults.set("v1", forKey: Prefs.kUpdateEtag)
        let checker = makeChecker { etag in
            XCTAssertEqual(etag, "v1")
            return .notModified
        }
        await checker.check(manual: false)
        XCTAssertTrue(checker.outdated)
        XCTAssertEqual(defaults.double(forKey: Prefs.kUpdateChecked), now)
    }

    func testInvalidResponseDoesNotOverwriteSavedResult() async {
        defaults.set(outdatedBody, forKey: Prefs.kUpdateBody)
        defaults.set("v1", forKey: Prefs.kUpdateEtag)
        let checker = makeChecker { _ in .ok(Data("{}".utf8), etag: "bad") }
        await checker.check(manual: false)
        XCTAssertTrue(checker.outdated)
        XCTAssertEqual(defaults.string(forKey: Prefs.kUpdateEtag), "v1")
        XCTAssertNil(defaults.object(forKey: Prefs.kUpdateChecked))
    }

    func testOfflineWithoutSavedResultDoesNotShowWarning() async {
        let checker = makeChecker { _ in .error("offline") }
        await checker.check(manual: false)
        XCTAssertFalse(checker.outdated)
        XCTAssertNil(defaults.object(forKey: Prefs.kUpdateChecked))
    }

    private func makeChecker(_ request: @escaping (String?) async -> NetResult) -> UpgradeChecker {
        UpgradeChecker(defaults: defaults, currentVersion: "2026.11.13", now: { self.now }, request: request)
    }
}
