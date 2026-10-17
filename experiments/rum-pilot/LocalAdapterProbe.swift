import Foundation
import Darwin

@main struct LocalAdapterProbe {
    static func main() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_RUM_LIMIT_VERIFIED"] == "1",
              ProcessInfo.processInfo.environment["RAWLAB_RUM_NETWORK"] == "china-telecom" else {
            fatalError("Local validation requires the operator-confirmed cap and direct network")
        }
        // RAWLAB_RUM_TARGET=production 时走正式包写死的上报目标（env=prod），否则为本地验证配置
        let production = ProcessInfo.processInfo.environment["RAWLAB_RUM_TARGET"] == "production"
        let configuration = production ? try RUMPCConfiguration.production() : try RUMPCConfiguration()
        guard let marker = configuration.validationRun else { fatalError("A random validation UUID is required") }
        alarm(60)
        guard let parent = ProcessInfo.processInfo.environment["RAWLAB_RUM_CACHE_PARENT"] else {
            fatalError("Run through local-adapter.sh for parent-owned cache cleanup")
        }
        // 探针用验证标记当设备标识，不碰本机真实的安装标识
        let transport = SerialUsageTransport(backend: AliyunRUMBackend(configuration: configuration,
            deviceID: { marker }, cacheParent: URL(fileURLWithPath: parent)))
        let failure = DispatchSemaphore(value: 0)
        transport.onFailure = { failure.signal() }
        try transport.start()
        for event: UsageEvent in [.appStarted, .photoImported, .filmSelected(.builtIn), .exportCompleted,
            .batchExportCompleted(succeeded: 2, failed: 1, outcome: .partial)] {
            transport.record(event)
        }
        transport.waitUntilIdle()
        guard failure.wait(timeout: .now()) == .timedOut else { fatalError("SDK startup failed") }
        sleep(15)
        transport.stop(); transport.waitUntilIdle()
        guard !transport.hasFailed else { fatalError("SDK lifecycle failed") }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: parent)
        guard !remaining.contains(where: { $0.hasPrefix("rawlab-rum-session-") }) else {
            fatalError("SDK private cache was not removed")
        }
        alarm(0)
        print("SUBMITTED: five synthetic usage events through the app adapter; cloud readback required")
    }
}
