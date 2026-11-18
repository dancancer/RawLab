import Foundation
import XCTest
@testable import RawLabKit

final class BatchSelectionSessionTests: XCTestCase {
    func testBatchSelectionOrderExclusionAndSyncHistory() {
        var session = BatchSelectionSession<String>()
        session.append(["source", "same-name-A", "same-name-B", "source", "third"])
        XCTAssertEqual(session.ordered, ["source", "same-name-A", "same-name-B", "third"])

        session.select("same-name-B", false)
        XCTAssertEqual(session.targets(excluding: "source"), ["same-name-A", "third"])
        XCTAssertTrue(session.beginEditing("third"))
        XCTAssertEqual(session.current, "third")
        XCTAssertEqual(session.returnPosition, "third")

        session.returnToCollection()
        XCTAssertNil(session.current)
        XCTAssertEqual(session.returnPosition, "third")
        XCTAssertEqual(session.selected, ["source", "same-name-A", "third"])

        let synchronization = UUID()
        session.recordSynchronization(synchronization, changed: true)
        session.recordSynchronization(UUID(), changed: false)
        XCTAssertEqual(session.lastSynchronization, synchronization)

        let skipped: Set<String> = ["same-name-A"]
        XCTAssertEqual(session.targets(excluding: "source").filter { !skipped.contains($0) }, ["third"])
        XCTAssertEqual(session.targets(excluding: "source"), ["same-name-A", "third"])

        session.remove("third")
        XCTAssertNil(session.returnPosition)
        XCTAssertFalse(session.selected.contains("third"))
        XCTAssertFalse(session.beginEditing("missing"))
    }
}
