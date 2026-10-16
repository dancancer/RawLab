import Foundation

private final class Backend: UsageSDKBackend {
    let entered = DispatchSemaphore(value: 0)
    let unblock = DispatchSemaphore(value: 0)
    let stopEntered = DispatchSemaphore(value: 0)
    let unblockStop = DispatchSemaphore(value: 0)
    var block = true
    var blockStop = false
    var fails = false
    var failsStop = false
    var calls: [String] = []
    func start() throws {
        calls.append("start"); entered.signal()
        if block { unblock.wait() }
        if fails { throw CocoaError(.featureUnsupported) }
    }
    func record(_ event: UsageEvent) { calls.append(event.name) }
    func stop() throws {
        calls.append("stop")
        stopEntered.signal()
        if blockStop { unblockStop.wait() }
        if failsStop { throw CocoaError(.featureUnsupported) }
    }
}

@main struct UsageTransportTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func main() throws {
        let backend = Backend()
        let transport = SerialUsageTransport(backend: backend)
        try transport.start()
        check(backend.entered.wait(timeout: .now() + 2) == .success, "start is off caller thread")
        transport.record(.photoImported)
        transport.stop()
        transport.record(.exportCompleted)
        backend.unblock.signal()
        transport.waitUntilIdle()
        check(backend.calls == ["start", "stop"], "withdrawal discards queued events and closes once")
        backend.block = false
        try transport.start()
        transport.record(.filmSelected(.custom))
        transport.waitUntilIdle()
        check(backend.calls.suffix(3) == ["start", "app_started", "film_selected"], "restart counts launch only after successful active start")
        transport.record(.appStarted); transport.waitUntilIdle()
        check(backend.calls.filter { $0 == "app_started" }.count == 1, "shared launch event cannot duplicate SDK-ready launch")
        transport.stop(); transport.waitUntilIdle()

        let failed = Backend(); failed.block = false; failed.fails = true
        let unavailable = SerialUsageTransport(backend: failed)
        let failure = DispatchSemaphore(value: 0)
        unavailable.onFailure = { failure.signal() }
        try unavailable.start(); unavailable.record(.photoImported)
        unavailable.waitUntilIdle()
        check(failure.wait(timeout: .now() + 1) == .success, "initialization failure is reported")
        check(failed.calls == ["start", "stop"], "failed start is cleaned without sending")
        let terminalBackend = Backend(); terminalBackend.block = false
        let terminal = SerialUsageTransport(backend: terminalBackend, allowsRestart: false)
        try terminal.start(); terminal.waitUntilIdle(); terminal.stop(); terminal.waitUntilIdle()
        check(!terminal.isAvailable && terminal.unavailableReason != nil, "mobile stopped SDK requires a process restart")
        do { try terminal.start(); fatalError("restarted a terminal SDK") } catch { }
        let stopFailed = Backend(); stopFailed.block = false; stopFailed.failsStop = true
        let blocked = SerialUsageTransport(backend: stopFailed)
        try blocked.start(); blocked.waitUntilIdle()
        blocked.stop(); blocked.waitUntilIdle()
        check(!blocked.isAvailable && blocked.hasFailed, "close failure blocks even restartable SDKs")
        do { try blocked.start(); fatalError("restarted after failed close") } catch { }
        blocked.record(.photoImported); blocked.stop(); blocked.waitUntilIdle()
        check(stopFailed.calls == ["start", "app_started", "stop"], "failed close cannot resume sending")
        let racing = Backend(); racing.block = false; racing.blockStop = true; racing.failsStop = true
        let racingTransport = SerialUsageTransport(backend: racing)
        try racingTransport.start(); racingTransport.waitUntilIdle(); racingTransport.stop()
        check(racing.stopEntered.wait(timeout: .now() + 1) == .success, "close is running")
        try racingTransport.start(); racingTransport.record(.photoImported)
        racing.unblockStop.signal(); racingTransport.waitUntilIdle()
        check(!racingTransport.isAvailable && racingTransport.hasFailed, "queued re-enable cannot bypass failed close")
        check(racing.calls == ["start", "app_started", "stop"], "failed close drops pending restart and events")
        print("PASS: asynchronous lifecycle, withdrawal, restart, startup and close failures")
    }
}
