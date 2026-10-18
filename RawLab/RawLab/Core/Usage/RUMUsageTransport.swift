import Foundation

// 本地验证构建（环境变量配置、独立包名）只能是 Debug；正式构建用 RAWLAB_RUM
#if RAWLAB_RUM_LOCAL && !DEBUG
#error("RUM local validation cannot be built for Release")
#endif

enum RawLabRUMThreading {
    static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }
}

enum RawLabRUMViewContext {
    static let name = "RawLab Usage"
    static let method = "manual"
    static let type: String? = nil

    static func makeID() -> String {
        "rawlab-usage-\(UUID().uuidString)"
    }
}

// 移动 SDK 停止后同进程不能再启动：关闭后重新开启需要重启应用
// 设备标识由调用方提供（正式为本机随机安装标识，探针为验证标记），不读取任何硬件编号
enum RawLabIOSUsageTransport {
    static let allowsRestart = false

    static func make(configuration: RUMConfiguration?,
                     deviceID: @escaping () throws -> String) -> UsageAnalyticsTransport {
#if RAWLAB_RUM
        guard let configuration else { return UnavailableUsageTransport() }
        return SerialUsageTransport(backend: AliyunRUMUsageBackend(configuration: configuration, deviceID: deviceID),
                                    allowsRestart: allowsRestart)
#else
        return UnavailableUsageTransport()
#endif
    }
}

#if RAWLAB_RUM
import AlibabaCloudRUM
import AlibabaCloudRUMSDK

private final class AliyunRUMUsageBackend: UsageSDKBackend {
    private let configuration: RUMConfiguration
    private let deviceID: () throws -> String
    private let localViewID = RawLabRUMViewContext.makeID()

    init(configuration: RUMConfiguration, deviceID: @escaping () throws -> String) {
        self.configuration = configuration; self.deviceID = deviceID
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    func start() throws {
        let disabledModules = try RUMConfiguration.disabledModules.map { rawModule in
            guard let module = AlibabaCloudModule(rawValue: rawModule) else {
                throw RUMConfigurationError.invalid("unsupported AlibabaCloudRUM module \(rawModule)")
            }
            return module
        }
        let device = try deviceID()
        let environment: Env = configuration.environment == .production ? .PROD : .LOCAL
        var localModuleMask: UInt = 0
        let configureAndStart = {
            disabledModules.forEach(AlibabaCloudRUM.disableModule)
            AlibabaCloudRUM.enableModule(.customEvent)
            localModuleMask = AlibabaCloudRUMSDK.moduleStates().rawValue
            AlibabaCloudRUM.setSelfMonitorEnabled(false)
            AlibabaCloudRUM.setEnvironment(environment)
            AlibabaCloudRUM.setAppVersion(Self.appVersion)
            AlibabaCloudRUM.setEndpoint(self.configuration.endpoint.absoluteString)
            AlibabaCloudRUM.setWorkspace(self.configuration.workspace)
            AlibabaCloudRUM.setDeviceID(device)
            if self.configuration.validationRun != nil {
                AlibabaCloudRUMSDK.setDebuggable(true)
            }
        }
        RawLabRUMThreading.onMain(configureAndStart)
        if configuration.validationRun != nil {
            print("RUM_MODULE_STATE: mask=\(localModuleMask)")
            fflush(stdout)
        }
        guard localModuleMask == (1 << 9) else {
            throw RUMConfigurationError.invalid("AlibabaCloudRUM local module policy did not resolve to customEvent only")
        }
        RawLabRUMThreading.onMain {
            AlibabaCloudRUM.start(self.configuration.serviceID)
        }

        // The mobile SDK loads remote configuration asynchronously; do not queue
        // the first custom event until that startup window has elapsed.
        Thread.sleep(forTimeInterval: 5)

        var coreIsStarted = false
        var hasActiveSession = false
        RawLabRUMThreading.onMain {
            // The wrapper discards the core start BOOL. Read the public core
            // state as a local validation guard before accepting events.
            coreIsStarted = AlibabaCloudRUMSDK.isStarted()
            hasActiveSession = !(AlibabaCloudRUM.getActiveSessionId() ?? "").isEmpty
        }
        if configuration.validationRun != nil {
            print("RUM_START_STATE: started=\(coreIsStarted) activeSession=\(hasActiveSession)")
            fflush(stdout)
        }
        guard coreIsStarted else {
            throw RUMConfigurationError.invalid("AlibabaCloudRUM SDK isStarted=false")
        }
        guard hasActiveSession else {
            throw RUMConfigurationError.invalid("AlibabaCloudRUM SDK isStarted=true but active session is missing")
        }
        RawLabRUMThreading.onMain {
            AlibabaCloudRUMSDK.reportView(self.localViewID,
                                          loadTime: 0,
                                          enter: true,
                                          name: RawLabRUMViewContext.name,
                                          method: RawLabRUMViewContext.method,
                                          map: [:],
                                          type: RawLabRUMViewContext.type)
        }
    }

    func record(_ event: UsageEvent) {
        var info = event.properties(platform: .ios)
        if let validationRun = configuration.validationRun {
            info["validation_run"] = validationRun.uuidString
        }
        AlibabaCloudRUM.setCustomEvent(event.name,
                                       group: event.group,
                                       snapshots: nil,
                                       value: Double(event.value),
                                       info: info)
    }

    func stop() throws {
        var stopSucceeded = false
        var coreIsStarted = true
        RawLabRUMThreading.onMain {
            AlibabaCloudRUMSDK.reportView(self.localViewID,
                                          loadTime: 0,
                                          enter: false,
                                          name: RawLabRUMViewContext.name,
                                          method: RawLabRUMViewContext.method,
                                          map: [:],
                                          type: RawLabRUMViewContext.type)
            stopSucceeded = AlibabaCloudRUMSDK.stop()
            coreIsStarted = AlibabaCloudRUMSDK.isStarted()
        }
        guard stopSucceeded, !coreIsStarted else {
            throw RUMConfigurationError.invalid("AlibabaCloudRUM SDK stop failed")
        }
    }
}
#endif
