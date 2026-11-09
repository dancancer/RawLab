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
        check(delegate.responds(to: #selector(NSApplicationDelegate.application(_:open:))),
              "system Open With events have an application delegate handler")
        let first = URL(fileURLWithPath: "/tmp/one photo.dng")
        let second = URL(fileURLWithPath: "/tmp/second.jpg")
        let systemDelegate: NSApplicationDelegate = delegate
        var requestedWindows = 0
        delegate.openEditorWindow = { requestedWindows += 1 }
        systemDelegate.application?(application, open: [first, second])
        systemDelegate.application?(application, open: [second])
        delegate.openEditorWindow = { requestedWindows += 1 }
        drain()
        check(requestedWindows == 1, "cold events and Scene rebinding request the singleton editor once before its runtime exists")
        var requests: [[URL]] = []
        var finishes: [(Bool) -> Void] = []
        delegate.openPhotos = { urls, finish in requests.append(urls); finishes.append(finish) }
        check(requests == [[first, second]], "a pending draft confirmation prevents dispatching the next cold-start request")
        finishes[0](true); drain()
        check(requests == [[first, second], [second]], "completed requests release the next group in original order")
        finishes[1](false); drain()
        check(requests.count == 2, "a blocked update or failed save retains the request without a busy retry loop")
        delegate.retryOpenPhotos()
        check(requests == [[first, second], [second], [second]], "a ready-state transition retries the retained request")
        finishes[2](true); drain()
        systemDelegate.application?(application, open: [first])
        check(requests == [[first, second], [second], [second], [first]], "warm requests reach the ready editor immediately")
        drain()
        check(requestedWindows == 2, "a warm event also reopens the singleton editor after its window was closed")
        finishes[3](true); drain()
        delegate.openPhotos = { urls, finish in requests.append(urls); finish(true) }
        check(requests.count == 4, "reattaching the editor does not replay consumed requests")
        let earlyDelegate = RawLabMacDelegate()
        earlyDelegate.application(application, open: [first])
        var earlyWindows = 0
        earlyDelegate.openEditorWindow = { earlyWindows += 1 }
        drain()
        check(earlyWindows == 1, "a document event arriving before Scene binding requests a window once binding is ready")
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
