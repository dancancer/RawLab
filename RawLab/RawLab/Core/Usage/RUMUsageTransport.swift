import Foundation

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

enum RawLabRUMLocalViewContext {
    static let name = "RawLab Usage"
    static let method = "manual"
    static let type: String? = nil

    static func makeID() -> String {
        "rawlab-usage-\(UUID().uuidString)"
    }
}

enum RawLabIOSUsageTransport {
    static let allowsRestart = false

    static func make(configuration: RUMLocalConfiguration?) -> UsageAnalyticsTransport {
#if RAWLAB_RUM_LOCAL
        guard let configuration else { return UnavailableUsageTransport() }
        return SerialUsageTransport(backend: AliyunRUMUsageBackend(configuration: configuration),
                                    allowsRestart: allowsRestart)
#else
        return UnavailableUsageTransport()
#endif
    }
}

#if RAWLAB_RUM_LOCAL
import AlibabaCloudRUM
import AlibabaCloudRUMSDK

private final class AliyunRUMUsageBackend: UsageSDKBackend {
    private let configuration: RUMLocalConfiguration
    private let localViewID = RawLabRUMLocalViewContext.makeID()

    init(configuration: RUMLocalConfiguration) {
        self.configuration = configuration
    }

    func start() throws {
        let disabledModules = try RUMLocalConfiguration.disabledModules.map { rawModule in
            guard let module = AlibabaCloudModule(rawValue: rawModule) else {
                throw RUMLocalConfigurationError.invalid("unsupported AlibabaCloudRUM module \(rawModule)")
            }
            return module
        }
        var localModuleMask: UInt = 0
        let configureAndStart = {
            disabledModules.forEach(AlibabaCloudRUM.disableModule)
            AlibabaCloudRUM.enableModule(.customEvent)
            localModuleMask = AlibabaCloudRUMSDK.moduleStates().rawValue
            AlibabaCloudRUM.setSelfMonitorEnabled(false)
            AlibabaCloudRUM.setEnvironment(.LOCAL)
            AlibabaCloudRUM.setAppVersion("0.0.0-local")
            AlibabaCloudRUM.setEndpoint(self.configuration.endpoint.absoluteString)
            AlibabaCloudRUM.setWorkspace(self.configuration.workspace)
            AlibabaCloudRUM.setDeviceID(self.configuration.deviceID.uuidString)
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
            throw RUMLocalConfigurationError.invalid("AlibabaCloudRUM local module policy did not resolve to customEvent only")
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
            throw RUMLocalConfigurationError.invalid("AlibabaCloudRUM SDK isStarted=false")
        }
        guard hasActiveSession else {
            throw RUMLocalConfigurationError.invalid("AlibabaCloudRUM SDK isStarted=true but active session is missing")
        }
        RawLabRUMThreading.onMain {
            AlibabaCloudRUMSDK.reportView(self.localViewID,
                                          loadTime: 0,
                                          enter: true,
                                          name: RawLabRUMLocalViewContext.name,
                                          method: RawLabRUMLocalViewContext.method,
                                          map: [:],
                                          type: RawLabRUMLocalViewContext.type)
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
                                          name: RawLabRUMLocalViewContext.name,
                                          method: RawLabRUMLocalViewContext.method,
                                          map: [:],
                                          type: RawLabRUMLocalViewContext.type)
            stopSucceeded = AlibabaCloudRUMSDK.stop()
            coreIsStarted = AlibabaCloudRUMSDK.isStarted()
        }
        guard stopSucceeded, !coreIsStarted else {
            throw RUMLocalConfigurationError.invalid("AlibabaCloudRUM SDK stop failed")
        }
    }
}
#endif
