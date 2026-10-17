import AppKit

final class EditorModel {
    var geometryDraftHasChanges = false
    var geometryDraftDeparturePending = false
    var canSave = true
    var leave: (() -> Void)?
    var stay: (() -> Void)?

    func saveEdits() -> Bool { canSave }
    func cancelGeometryDraft() { geometryDraftHasChanges = false }
    func requestLeavingGeometryDraft(_ action: @escaping () -> Void, onStay: @escaping () -> Void = {}) {
        geometryDraftDeparturePending = true
        leave = action
        stay = onStay
    }
}

#if RAWLAB_RUM
enum UsageRUM {
    static var completions: [() -> Void] = []
    static func shutdown(_ completion: @escaping () -> Void) { completions.append(completion) }
}
#endif

final class RecordingApplication: NSApplication {
    var replies: [Bool] = []
    override func reply(toApplicationShouldTerminate shouldTerminate: Bool) { replies.append(shouldTerminate) }
}

@main
struct UsageTerminationTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { print("FAIL: \(message)"); exit(1) }
    }

    static func drain() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    }

    static func main() {
        let application = RecordingApplication()
        let delegate = RawLabMacDelegate()
        let model = EditorModel()
        delegate.model = model

        model.geometryDraftHasChanges = true
        check(delegate.applicationShouldTerminate(application) == .terminateLater, "draft confirmation defers termination")
        check(application.replies.isEmpty, "confirmation must not terminate early")
        model.geometryDraftHasChanges = false
        model.geometryDraftDeparturePending = false
        model.leave?()
#if RAWLAB_RUM
        check(application.replies.isEmpty && UsageRUM.completions.count == 1, "termination waits for SDK shutdown")
        check(RawLabMacDelegate.usageShutdownLimit <= 3, "offline SDK shutdown cannot hold exit for long")
        UsageRUM.completions[0]()
        UsageRUM.completions[0]()
        drain()
#endif
        check(application.replies == [true], "confirmed draft exit replies exactly once")

        application.replies = []
        model.geometryDraftHasChanges = true
        check(delegate.applicationShouldTerminate(application) == .terminateLater, "second draft confirmation defers")
        model.stay?()
        check(application.replies == [false], "staying cancels deferred termination")
        check(delegate.applicationShouldTerminate(application) == .terminateCancel, "pending confirmation rejects another termination")

        application.replies = []
        model.geometryDraftHasChanges = false
        model.geometryDraftDeparturePending = false
        model.canSave = false
        check(delegate.applicationShouldTerminate(application) == .terminateCancel, "failed save cancels termination")
        check(application.replies.isEmpty, "failed save never permits termination")

        model.canSave = true
        let result = delegate.applicationShouldTerminate(application)
#if RAWLAB_RUM
        check(result == .terminateLater && UsageRUM.completions.count == 2, "clean exit waits for SDK")
        UsageRUM.completions[1]()
        drain()
        check(application.replies == [true], "clean exit replies after shutdown")
#else
        check(result == .terminateNow && application.replies.isEmpty, "clean default exit returns directly")
#endif
        print("PASS: draft exit confirmation, cancellation, save failure and SDK shutdown preserve termination replies")
    }
}
