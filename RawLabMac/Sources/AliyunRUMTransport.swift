#if RAWLAB_RUM_LOCAL
import Foundation
import RawLabRUMNative

final class AliyunRUMBackend: UsageSDKBackend {
    private let configuration: RUMPCConfiguration
    private var options: OpaquePointer?
    private var cache: URL?
    private var started = false
    private let cacheParent: URL
    init(configuration: RUMPCConfiguration, cacheParent: URL = FileManager.default.temporaryDirectory) {
        self.configuration = configuration; self.cacheParent = cacheParent
    }
    func start() throws {
        guard !started else { throw CocoaError(.featureUnsupported) }
        guard options == nil else { throw CocoaError(.featureUnsupported) }
        let directory = cacheParent.appendingPathComponent("rawlab-rum-session-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        cache = directory
        guard let value = alibabacloud_rum_options_new() else { throw CocoaError(.coderInvalidValue) }
        options = value
        alibabacloud_rum_options_set_config_address(value, configuration.configAddress)
        alibabacloud_rum_options_set_app_id(value, configuration.appID)
        alibabacloud_rum_options_set_app_name(value, "RawLab Local Validation")
        alibabacloud_rum_options_set_app_version(value, "0.0.0-local")
        alibabacloud_rum_options_set_env(value, ALIBABACLOUD_RUM_ENV_LOCAL)
        alibabacloud_rum_options_set_cache_path(value, directory.path)
        alibabacloud_rum_options_set_utdid(value, UUID().uuidString)
        alibabacloud_rum_options_set_debug_level(value, ALIBABACLOUD_RUM_LEVEL_FATAL)
        alibabacloud_rum_options_set_auto_crash_tracking(value, 0)
        alibabacloud_rum_options_set_auto_curl_tracking(value, 0)
        alibabacloud_rum_options_set_auto_cef_tracking(value, 0)
        guard alibabacloud_rum_init(value) == 0 else { throw CocoaError(.featureUnsupported) }
        started = true
    }
    func record(_ event: UsageEvent) {
        guard started, let native = alibabacloud_rum_custom_event_new("usage", event.name) else { return }
        alibabacloud_rum_custom_event_set_group(native, event.group)
        alibabacloud_rum_custom_event_set_value(native, Double(event.value))
        for (key, value) in event.properties(platform: .macos) {
            alibabacloud_rum_custom_event_add_extra(native, key, value)
        }
        if let marker = configuration.validationRun {
            alibabacloud_rum_custom_event_add_extra(native, "validation_run", marker)
        }
        alibabacloud_rum_custom_event_report(native)
    }
    func stop() throws {
        // 关闭失败时保留 options，避免 SDK 尚在使用的指针被提前释放。
        if options != nil, alibabacloud_rum_close() != 0 { throw CocoaError(.featureUnsupported) }
        started = false
        if let options { alibabacloud_rum_options_free(options); self.options = nil }
        if let cache { try FileManager.default.removeItem(at: cache); self.cache = nil }
    }
}

enum LocalRUM {
    private static var transport: SerialUsageTransport?
    static func configure() {
        guard let configuration = try? RUMPCConfiguration() else { return }
        let value = SerialUsageTransport(backend: AliyunRUMBackend(configuration: configuration))
        transport = value
        UsageAnalytics.shared.configure(value)
    }
    static func shutdown(_ completion: @escaping () -> Void) {
        UsageAnalytics.shared.endSession()
        guard let transport else { DispatchQueue.main.async(execute: completion); return }
        transport.whenIdle { DispatchQueue.main.async(execute: completion) }
    }
}
#endif
