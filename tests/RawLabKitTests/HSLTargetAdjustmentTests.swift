import Foundation
import XCTest
@testable import RawLabKit

final class HSLTargetAdjustmentTests: XCTestCase {
    func testHSLTargetAdjustmentDragRevisionAndCancellation() {
        let revision = HSLTargetRevision(source: 4, request: 9)
        let sample = HSLTargetSample(
            revision: revision,
            availability: .available,
            rgb: [1, 0.25, 0],
            weights: [0.5, 0.5, 0, 0, 0, 0, 0, 0],
            preview: true
        )
        var before = HSLSettings()
        before.setExact(.hue, channel: 0, value: 95.25)
        before.setExact(.hue, channel: 1, value: -12.5)
        before.setExact(.saturation, channel: 4, value: 23.75)

        for axis in HSLAxis.allCases {
            let drag = HSLTargetDrag(before: before, axis: axis, sample: sample)!
            let next = drag.value(delta: 20)
            XCTAssertEqual(next.value(axis, channel: 0), min(100, before.value(axis, channel: 0) + 10))
            XCTAssertEqual(next.value(axis, channel: 1), before.value(axis, channel: 1) + 10)
            XCTAssertEqual(drag.value(delta: 20), next)
            XCTAssertEqual(drag.value(delta: 0), before)
            XCTAssertEqual(drag.value(delta: -20).value(axis, channel: 1), before.value(axis, channel: 1) - 10)
            for other in HSLAxis.allCases {
                for channel in 0..<8 where other != axis || channel > 1 {
                    XCTAssertEqual(next.value(other, channel: channel), before.value(other, channel: channel))
                }
            }
            XCTAssertEqual(drag.value(delta: .nan), before)
        }

        XCTAssertEqual(sample.channels, [0, 1])
        let invalid = HSLTargetSample(revision: revision, availability: .nearGray, rgb: [0.5, 0.5, 0.5], weights: Array(repeating: 0, count: 8), preview: true)
        XCTAssertNil(HSLTargetDrag(before: before, axis: .hue, sample: invalid))

        var state = HSLTargetInteraction()
        let token = state.begin(before: before, axis: .hue, revision: revision)
        XCTAssertNil(state.move(delta: 20))
        XCTAssertNil(state.accept(sample, token: token, currentRevision: HSLTargetRevision(source: 5, request: 9)))
        XCTAssertNil(state.accept(sample, token: token, currentRevision: revision))

        let second = state.begin(before: before, axis: .saturation, revision: revision)
        state.move(delta: 20)
        let accepted = state.accept(sample, token: second, currentRevision: revision)!
        XCTAssertEqual(accepted.value(.saturation, channel: 0), 10)
        XCTAssertTrue(state.isDragging)

        XCTAssertEqual(state.cancel(), before)
        XCTAssertFalse(state.isDragging)
        XCTAssertNil(state.selection)

        let third = state.begin(before: before, axis: .lightness, revision: revision)
        state.move(delta: 12)
        state.end()
        state.accumulateReleased(delta: 2)
        XCTAssertEqual(state.accept(sample, token: third, currentRevision: revision)?.value(.lightness, channel: 1), 7)
        XCTAssertFalse(state.isDragging)
        XCTAssertEqual(state.selection, sample)

        let old = state.begin(before: before, axis: .hue, revision: revision)
        state.cancel()
        XCTAssertNil(state.accept(sample, token: old, currentRevision: revision))

        let badWeights = HSLTargetSample(revision: revision, availability: .available, rgb: [1, 0, 0], weights: [1, 1], preview: true)
        XCTAssertNil(HSLTargetDrag(before: before, axis: .hue, sample: badWeights))
    }
}
