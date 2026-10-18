#if RAWLAB_RUM
import Foundation
import Darwin

// ----------------------------------------------------------------------------
//  合成验证探针：经应用自己的适配层发送五条固定事件，供云端回读核对
//  只在启动时设置 RAWLAB_RUM_VALIDATE=1 与 UUID 标记才运行；不开启日常统计，
//  以验证标记作设备标识，不碰本机真实的安装标识
// ----------------------------------------------------------------------------
enum RUMValidationProbe {
    private static func report(_ message: String) {
        print(message)
        fflush(stdout)
    }

    static func run(configuration: RUMConfiguration, marker: UUID) {
        guard let transport = RawLabIOSUsageTransport.make(configuration: configuration,
                                                           deviceID: { marker.uuidString }) as? SerialUsageTransport else {
            report("NOT SENT: RUM transport is unavailable")
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
        report("SUBMITTED: five synthetic iOS usage events through the app adapter; cloud readback required")
    }
}

// 应用接线：正式构建用写死的正式配置，本地验证构建用环境变量配置
enum RawLabRUM {
    /// 返回 true 表示本次启动只跑验证探针，不开始日常统计
    static func start(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let configuration = try? configuration(environment) else {
            guard environment["RAWLAB_RUM_VALIDATE"] == "1" else { return false }
            print("NOT SENT: invalid iOS RUM validation configuration")
            return true
        }
        if let marker = configuration.validationRun {
            DispatchQueue.global(qos: .utility).async { RUMValidationProbe.run(configuration: configuration, marker: marker) }
            return true
        }
        UsageAnalytics.shared.configure(RawLabIOSUsageTransport.make(configuration: configuration,
                                                                     deviceID: FileUsageConsentStore.standard.installID))
        return false
    }

    private static func configuration(_ environment: [String: String]) throws -> RUMConfiguration {
#if RAWLAB_RUM_LOCAL
        try RUMConfiguration(environment: environment)
#else
        try RUMConfiguration.production(environment: environment)
#endif
    }
}
#endif
