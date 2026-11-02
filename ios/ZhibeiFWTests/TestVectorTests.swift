import XCTest
@testable import ZhibeiFW

// 两端共用的测试数据（仓库根目录 doc/test-vectors/*.json）：Android 的 TestVectorTest.kt 读同一份，用例不会两边抄岔。

final class TestVectorTests: XCTestCase {
    private func load(_ name: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("doc/test-vectors/\(name).json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// JSON 里的 null 读出来是 NSNull，传给被测函数时换成 nil
    private func value(_ v: Any) -> Any? { v is NSNull ? nil : v }

    func testVersions() throws {
        let v = try load("versions")
        for c in v["compare"] as! [[Any]] {
            XCTAssertEqual(compareVersions(c[0], c[1]), c[2] as? Int, "\(c)")
        }
        for c in v["invalid"] as! [[Any]] {
            XCTAssertNil(compareVersions(value(c[0]), value(c[1])), "\(c)")
        }
    }

    func testIds() throws {
        let v = try load("ids")
        for s in v["valid"] as! [Any] { XCTAssertTrue(isValidId(s), "\(s)") }
        for s in v["invalid"] as! [Any] { XCTAssertFalse(isValidId(s), "\(s)") }
    }

    func testPaths() throws {
        let v = try load("paths")
        for s in v["valid"] as! [Any] { XCTAssertTrue(isValidRelativePath(s), "\(s)") }
        for s in v["invalid"] as! [Any] { XCTAssertFalse(isValidRelativePath(s), "\(s)") }
    }

    func testOrigins() throws {
        let v = try load("origins")
        for s in v["valid"] as! [String] { XCTAssertTrue(isHttpsOrigin(s), s) }
        for s in v["invalid"] as! [String] { XCTAssertFalse(isHttpsOrigin(s), s) }
    }

    func testFileKeys() throws {
        let v = try load("filekey")
        for c in v["fileKey"] as! [[String]] { XCTAssertEqual(fileKey(c[0]), c[1], c[0]) }
        for c in v["placeholderIndex"] as! [[Any]] {
            XCTAssertEqual(placeholderIndex(c[0] as! String), c[1] as? Int, "\(c)")
        }
    }

    func testText() throws {
        let v = try load("text")
        for c in v["normalize"] as! [[String]] { XCTAssertEqual(normalizeText(c[0]), c[1]) }
        for c in v["clock"] as! [[Any]] { XCTAssertEqual(clock((c[0] as! NSNumber).doubleValue), c[1] as? String, "\(c)") }
        for c in v["remainingClock"] as! [[Any]] {
            XCTAssertEqual(remainingClock((c[0] as! NSNumber).doubleValue, (c[1] as! NSNumber).doubleValue), c[2] as? String, "\(c)")
        }
        for c in v["utf16Prefix"] as! [[Any]] {
            XCTAssertEqual(String(utf16Prefix: c[0] as! String, c[1] as! Int), c[2] as? String, "\(c)")
        }
    }
}
