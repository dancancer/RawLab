import Foundation

@main enum HSLTargetAdjustmentTests {
    static func require(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
    static func main() {
        let revision = HSLTargetRevision(source: 4, request: 9)
        let sample = HSLTargetSample(revision: revision, availability: .available,
            rgb: [1, 0.25, 0], weights: [0.5, 0.5, 0, 0, 0, 0, 0, 0], preview: true)
        var before = HSLSettings()
        before.setExact(.hue, channel: 0, value: 95.25)
        before.setExact(.hue, channel: 1, value: -12.5)
        before.setExact(.saturation, channel: 4, value: 23.75)
        for axis in HSLAxis.allCases {
            let drag = HSLTargetDrag(before: before, axis: axis, sample: sample)!
            let next = drag.value(delta: 20)
            require(next.value(axis, channel: 0) == min(100, before.value(axis, channel: 0) + 10), "first weighted channel")
            require(next.value(axis, channel: 1) == before.value(axis, channel: 1) + 10, "adjacent weighted channel")
            require(drag.value(delta: 20) == next, "repeated move does not accumulate")
            require(drag.value(delta: 0) == before, "zero delta preserves fractional saved values")
            require(drag.value(delta: -20).value(axis, channel: 1) == before.value(axis, channel: 1) - 10, "reverse is from frozen before")
            for other in HSLAxis.allCases { for channel in 0..<8 where other != axis || channel > 1 {
                require(next.value(other, channel: channel) == before.value(other, channel: channel), "unselected field unchanged")
            } }
            require(drag.value(delta: .nan) == before, "nonfinite input cannot corrupt settings")
        }
        require(sample.channels == [0, 1], "display actual adjacent channels")
        let invalid = HSLTargetSample(revision: revision, availability: .nearGray, rgb: [0.5, 0.5, 0.5], weights: Array(repeating: 0, count: 8), preview: true)
        require(HSLTargetDrag(before: before, axis: .hue, sample: invalid) == nil, "gray cannot start a drag")
        var state = HSLTargetInteraction()
        let token = state.begin(before: before, axis: .hue, revision: revision)
        require(state.move(delta: 20) == nil, "pending sample cannot update values")
        require(state.accept(sample, token: token, currentRevision: HSLTargetRevision(source: 5, request: 9)) == nil, "changed source rejects async result")
        require(state.accept(sample, token: token, currentRevision: revision) == nil, "stale pending interaction is discarded")
        let second = state.begin(before: before, axis: .saturation, revision: revision)
        state.move(delta: 20)
        let accepted = state.accept(sample, token: second, currentRevision: revision)!
        require(accepted.value(.saturation, channel: 0) == 10 && state.isDragging, "pending movement applies once after matching sample")
        require(state.cancel() == before && !state.isDragging && state.selection == nil, "cancel restores before and drops selection")
        let third = state.begin(before: before, axis: .lightness, revision: revision)
        state.move(delta: 12); state.end(); state.accumulateReleased(delta: 2)
        require(state.accept(sample, token: third, currentRevision: revision)!.value(.lightness, channel: 1) == 7 && !state.isDragging,
            "release before async answer produces one final frozen value")
        require(state.selection == sample, "released sample remains available for keyboard targeting")
        let old = state.begin(before: before, axis: .hue, revision: revision)
        state.cancel()
        require(state.accept(sample, token: old, currentRevision: revision) == nil, "cancelled callback cannot revive an interaction")
        let badWeights = HSLTargetSample(revision: revision, availability: .available, rgb: [1, 0, 0], weights: [1, 1], preview: true)
        require(HSLTargetDrag(before: before, axis: .hue, sample: badWeights) == nil, "invalid weights rejected")
        print("PASS HSL target axes, frozen weighted deltas, range, cancellation and async revision binding")
    }
}
