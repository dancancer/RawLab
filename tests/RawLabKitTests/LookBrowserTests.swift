import Foundation
import XCTest
@testable import RawLabKit

final class LookBrowserTests: XCTestCase {
    func testLookCategoriesSearchAndRecentLooksPersistence() throws {
        let items = [
            LookBrowserItem(id: "builtin:a", name: "Été doux", group: .fuji, isCustom: false),
            LookBrowserItem(id: "builtin:b", name: "Kodak Gold", group: .kodak, isCustom: false),
            LookBrowserItem(id: "managed:1", name: "My Winter", group: .other, isCustom: true)
        ]
        var browser = LookBrowserState()
        XCTAssertEqual(browser.visibleIDs(in: items, recent: []), items.map(\.id))
        browser.query = "ETE"
        XCTAssertEqual(browser.visibleIDs(in: items, recent: []), ["builtin:a"])
        browser.query = "no such look"
        XCTAssertTrue(browser.visibleIDs(in: items, recent: []).isEmpty)
        browser.query = ""
        browser.category = .custom
        XCTAssertEqual(browser.visibleIDs(in: items, recent: []), ["managed:1"])
        browser.category = .kodak
        XCTAssertEqual(browser.visibleIDs(in: items, recent: []), ["builtin:b"])
        browser.category = .recent
        XCTAssertEqual(browser.visibleIDs(in: items, recent: ["managed:1", "missing", "builtin:a"]), ["managed:1", "builtin:a"])

        let ids = (0..<14).map { "look:\($0)" }
        let available = Set(ids)
        var recent = RecentLooks()
        ids.forEach { recent.record($0, available: available) }
        XCTAssertEqual(recent.ids.count, 12)
        XCTAssertEqual(recent.ids.first, "look:13")
        XCTAssertFalse(recent.ids.contains("look:0"))

        recent.record("look:8", available: available)
        XCTAssertEqual(recent.ids.first, "look:8")
        XCTAssertEqual(recent.ids.filter { $0 == "look:8" }.count, 1)

        recent.prune(available: ["look:8", "look:5"])
        XCTAssertEqual(recent.ids, ["look:8", "look:5"])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("look-browser-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recent.json")
        try recent.save(to: url)
        XCTAssertEqual(RecentLooks.load(from: url), recent)
        XCTAssertEqual(RecentLooks(ids: ["a", "a", "b"]).ids, ["a", "b"])
    }
}
