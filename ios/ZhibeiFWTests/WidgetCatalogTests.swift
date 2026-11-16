import XCTest
@testable import ZhibeiFW

private final class CatalogResponseProtocol: URLProtocol {
    static var respond: ((CatalogResponseProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "widget-review.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        DispatchQueue.main.async { Self.respond?(self) }
    }
    override func stopLoading() {}
    func finish() {
        let data = Data(
            #"{"categories":[{"id":"c","name":"分类","series":[{"id":"s","title":"课程","coverPath":"cover.jpg","status":"completed","episodes":[{"id":"e","title":"第一集","audioPath":"e.mp3"}]}]}]}"#
                .utf8)
        client?.urlProtocol(
            self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class WidgetCatalogTests: XCTestCase {
    @MainActor
    func testCatalogRefreshPreservesPauseWrittenDuringRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = dir.appendingPathComponent("snapshot.json")
        defer {
            try? FileManager.default.removeItem(at: dir)
            CatalogResponseProtocol.respond = nil
            session.invalidateAndCancel()
        }
        let item = WidgetItem(seriesId: "s", seriesTitle: "课程", episodeId: "e", color: 0)
        let snapshot = WidgetSnapshot(
            nowPlaying: WidgetNowPlaying(item: item, position: 30, duration: 600, playing: true, loaded: true),
            origin: "https://widget-review.invalid")
        WidgetStore.update(at: file) { $0 = snapshot }
        var intercepted = false
        CatalogResponseProtocol.respond = { request in
            intercepted = true
            var paused = snapshot
            paused.nowPlaying?.playing = false
            WidgetStore.update(at: file) { $0 = paused }
            request.finish()
        }
        let result = await WidgetCatalog.refresh(snapshot, using: session, directory: dir)
        XCTAssertTrue(intercepted, "必须实际经过受控请求")
        XCTAssertNotNil(result, "目录刷新应已写入")
        let saved = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.nowPlaying?.playing, false, "目录刷新不得把暂停后的状态恢复为播放")
    }
}
