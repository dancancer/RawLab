import Foundation

private struct Work: Equatable {
    let fileID: String
    let revision: Int
}

@main
struct RenderSchedulingTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("FAIL: \(message)") }
        print("PASS: \(message)")
    }

    static func main() {
        latestOnlyCoalescesPendingWork()
        continuousDragKeepsLatestPreviewReady()
        fileSwitchDiscardsOldWork()
        releaseAlwaysSchedulesExactWork()
        proxyCannotWinAfterExactWork()
        numericChangesAreExact()
        busyCoversInteractiveAndPendingExactWork()
        invalidationWaitsForPreparedInputs()
    }

    private static func invalidationWaitsForPreparedInputs() {
        var scheduler = RenderScheduler<Work>()
        let old = scheduler.submit(Work(fileID: "one", revision: 1), fileID: "one")
        _ = scheduler.startNext()
        _ = scheduler.submit(Work(fileID: "one", revision: 2), fileID: "one")
        scheduler.invalidatePending()
        check(!scheduler.hasPending && scheduler.finish(old) == .discard,
              "Waiting for AI discards old rendering and does not launch an unprepared frame")
        check(!scheduler.isBusy, "Discarded preparation does not leave the render queue busy")
        let ready = scheduler.submit(Work(fileID: "one", revision: 2), fileID: "one")
        check(scheduler.startNext() == ready && scheduler.finish(ready) == .publishExact,
              "Prepared inputs resume exact rendering")

        scheduler.setInteracting(true)
        let staleProxy = scheduler.submit(Work(fileID: "one", revision: 3), fileID: "one")
        _ = scheduler.startNext()
        scheduler.invalidatePending()
        scheduler.setInteracting(false)
        let prepared = scheduler.submit(Work(fileID: "one", revision: 4), fileID: "one")
        check(scheduler.finish(staleProxy) == .discard,
              "Invalidated interactive work cannot publish after AI preparation finishes")
        check(scheduler.startNext() == prepared && scheduler.finish(prepared) == .publishExact,
              "The prepared exact request follows the discarded interactive work")
    }

    private static func latestOnlyCoalescesPendingWork() {
        var scheduler = RenderScheduler<Work>()
        _ = scheduler.submit(Work(fileID: "one", revision: 1), fileID: "one")
        let latest = scheduler.submit(Work(fileID: "one", revision: 2), fileID: "one")
        check(scheduler.pending == latest, "new settings replace the single pending request")
        check(scheduler.startNext() == latest, "the executor starts only the latest coalesced request")
    }

    private static func continuousDragKeepsLatestPreviewReady() {
        var scheduler = RenderScheduler<Work>()
        scheduler.setInteracting(true)
        let first = scheduler.submit(Work(fileID: "one", revision: 1), fileID: "one")
        _ = scheduler.startNext()
        _ = scheduler.submit(Work(fileID: "one", revision: 2), fileID: "one")
        let latest = scheduler.submit(Work(fileID: "one", revision: 3), fileID: "one")
        check(scheduler.inFlight == first && scheduler.pending == latest,
              "continuous slider events keep one proxy in flight and replace pending work")
        check(scheduler.finish(first) == .publishInteractive, "the completed proxy remains displayable during a drag")
        check(scheduler.startNext() == latest, "the latest drag value starts as soon as the proxy finishes")
    }

    private static func fileSwitchDiscardsOldWork() {
        var scheduler = RenderScheduler<Work>()
        let old = scheduler.submit(Work(fileID: "one", revision: 1), fileID: "one")
        _ = scheduler.startNext()
        let current = scheduler.submit(Work(fileID: "two", revision: 1), fileID: "two")
        check(scheduler.finish(old) == .discard, "a completed render from an old file never publishes")
        check(scheduler.startNext() == current, "the new file remains queued after the old render finishes")
        check(scheduler.finish(current) == .publishExact, "the current file can publish its exact result")
    }

    private static func releaseAlwaysSchedulesExactWork() {
        var scheduler = RenderScheduler<Work>()
        scheduler.setInteracting(true)
        let preview = scheduler.submit(Work(fileID: "one", revision: 1), fileID: "one")
        check(preview.pass == .interactive, "slider changes use the interactive pass")
        scheduler.setInteracting(false)
        let exact = scheduler.submit(Work(fileID: "one", revision: 1), fileID: "one")
        check(exact.pass == .exact, "slider release queues an exact pass even without a new value")
    }

    private static func proxyCannotWinAfterExactWork() {
        var scheduler = RenderScheduler<Work>()
        scheduler.setInteracting(true)
        let preview = scheduler.submit(Work(fileID: "one", revision: 1), fileID: "one")
        _ = scheduler.startNext()
        scheduler.setInteracting(false)
        let exact = scheduler.submit(Work(fileID: "one", revision: 2), fileID: "one")
        check(scheduler.finish(preview) == .publishInteractive, "an in-flight proxy may remain visible while exact work is pending")
        check(scheduler.startNext() == exact, "the pending exact result follows the in-flight proxy")
        check(scheduler.finish(exact) == .publishExact, "the latest exact result wins after the proxy")
    }

    private static func numericChangesAreExact() {
        var scheduler = RenderScheduler<Work>()
        let typed = scheduler.submit(Work(fileID: "one", revision: 3), fileID: "one")
        check(typed.pass == .exact, "numeric input remains an exact render request")
        _ = scheduler.startNext()
        check(scheduler.finish(typed) == .publishExact, "numeric input publishes an exact result")
    }

    private static func busyCoversInteractiveAndPendingExactWork() {
        var scheduler = RenderScheduler<Work>()
        scheduler.setInteracting(true)
        let preview = scheduler.submit(Work(fileID: "one", revision: 1), fileID: "one")
        check(scheduler.isBusy, "export stays blocked while interaction is active")
        _ = scheduler.startNext()
        _ = scheduler.finish(preview)
        check(scheduler.isBusy, "export stays blocked while interaction remains active")
        scheduler.setInteracting(false)
        let exact = scheduler.submit(Work(fileID: "one", revision: 1), fileID: "one")
        check(scheduler.isBusy, "export stays blocked while the release exact render is pending")
        _ = scheduler.startNext()
        _ = scheduler.finish(exact)
        check(!scheduler.isBusy, "export is unblocked only after exact rendering finishes")
    }
}
