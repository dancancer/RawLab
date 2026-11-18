import Foundation
import XCTest
@testable import RawLabKit

private final class MockUsageSDKBackend: UsageSDKBackend {
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
        calls.append("start")
        entered.signal()
        if block { unblock.wait() }
        if fails { throw CocoaError(.featureUnsupported) }
    }

    func record(_ event: UsageEvent) {
        calls.append(event.name)
    }

    func stop() throws {
        calls.append("stop")
        stopEntered.signal()
        if blockStop { unblockStop.wait() }
        if failsStop { throw CocoaError(.featureUnsupported) }
    }
}

final class UsageTransportTests: XCTestCase {
    func testAsyncLifecycleWithdrawalRestartAndFailures() throws {
        let backend = MockUsageSDKBackend()
        let transport = SerialUsageTransport(backend: backend)
        try transport.start()
        XCTAssertEqual(backend.entered.wait(timeout: .now() + 2), .success)
        transport.record(.photoImported)
        transport.stop()
        transport.record(.exportCompleted)
        backend.unblock.signal()
        transport.waitUntilIdle()
        XCTAssertEqual(backend.calls, ["start", "stop"])

        backend.block = false
        try transport.start()
        transport.record(.filmSelected(.custom))
        transport.waitUntilIdle()
        XCTAssertEqual(Array(backend.calls.suffix(3)), ["start", "app_started", "film_selected"])

        transport.record(.appStarted)
        transport.waitUntilIdle()
        XCTAssertEqual(backend.calls.filter { $0 == "app_started" }.count, 1)
        transport.stop()
        transport.waitUntilIdle()

        let failed = MockUsageSDKBackend()
        failed.block = false
        failed.fails = true
        let unavailable = SerialUsageTransport(backend: failed)
        let failure = DispatchSemaphore(value: 0)
        unavailable.onFailure = { failure.signal() }
        try unavailable.start()
        unavailable.record(.photoImported)
        unavailable.waitUntilIdle()
        XCTAssertEqual(failure.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(failed.calls, ["start", "stop"])

        let terminalBackend = MockUsageSDKBackend()
        terminalBackend.block = false
        let terminal = SerialUsageTransport(backend: terminalBackend, allowsRestart: false)
        try terminal.start()
        terminal.waitUntilIdle()
        terminal.stop()
        terminal.waitUntilIdle()
        XCTAssertFalse(terminal.isAvailable)
        XCTAssertNotNil(terminal.unavailableReason)
        XCTAssertThrowsError(try terminal.start())

        let stopFailed = MockUsageSDKBackend()
        stopFailed.block = false
        stopFailed.failsStop = true
        let blocked = SerialUsageTransport(backend: stopFailed)
        try blocked.start()
        blocked.waitUntilIdle()
        blocked.stop()
        blocked.waitUntilIdle()
        XCTAssertFalse(blocked.isAvailable)
        XCTAssertTrue(blocked.hasFailed)
        XCTAssertThrowsError(try blocked.start())
        blocked.record(.photoImported)
        blocked.stop()
        blocked.waitUntilIdle()
        XCTAssertEqual(stopFailed.calls, ["start", "app_started", "stop"])

        let racing = MockUsageSDKBackend()
        racing.block = false
        racing.blockStop = true
        racing.failsStop = true
        let racingTransport = SerialUsageTransport(backend: racing)
        try racingTransport.start()
        racingTransport.waitUntilIdle()
        racingTransport.stop()
        XCTAssertEqual(racing.stopEntered.wait(timeout: .now() + 1), .success)
        try racingTransport.start()
        racingTransport.record(.photoImported)
        racing.unblockStop.signal()
        racingTransport.waitUntilIdle()
        XCTAssertFalse(racingTransport.isAvailable)
        XCTAssertTrue(racingTransport.hasFailed)
        XCTAssertEqual(racing.calls, ["start", "app_started", "stop"])
    }
}
