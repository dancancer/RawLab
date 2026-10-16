#if RAWLAB_RUM_LOCAL
import Foundation
import Darwin

enum RUMLocalValidationProbe {
    private static func report(_ message: String) {
        print(message)
        fflush(stdout)
    }

    static func run(configuration: RUMLocalConfiguration) {
        guard let transport = RawLabIOSUsageTransport.make(configuration: configuration) as? SerialUsageTransport else {
            report("NOT SENT: local RUM transport is unavailable")
            return
        }

        let failure = DispatchSemaphore(value: 0)
        transport.onFailure = { failure.signal() }
        do { try transport.start() }
        catch {
            report("NOT SENT / FAILED: \(error.localizedDescription)")
            return
        }
        transport.waitUntilIdle()
        guard failure.wait(timeout: .now()) == .timedOut else {
            report("NOT SENT / FAILED: SDK initialization failed")
            return
        }
        report("RUM_PROBE_PHASE: started")

        let events: [UsageEvent] = [
            .appStarted,
            .photoImported,
            .filmSelected(.builtIn),
            .exportCompleted,
            .batchExportCompleted(succeeded: 2, failed: 1, outcome: .partial),
        ]
        events.forEach(transport.record)
        transport.waitUntilIdle()
        report("RUM_PROBE_PHASE: recorded")
        sleep(15)
        report("RUM_PROBE_PHASE: stopping")
        transport.stop()
        transport.waitUntilIdle()
        report("RUM_PROBE_PHASE: stopped")
        guard !transport.hasFailed else {
            report("NOT SENT / FAILED: SDK stop failed")
            return
        }
        report("SUBMITTED: five synthetic iOS usage events through the local adapter; cloud readback required")
    }
}
#endif
