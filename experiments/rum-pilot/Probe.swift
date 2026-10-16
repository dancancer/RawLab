import Foundation
import Darwin

@main
struct RUMPilotProbe {
    static func main() {
        do {
            if CommandLine.arguments.dropFirst() == ["--help"] {
                print("Usage: bash experiments/rum-pilot/run.sh [--check|--send|--help]")
                print("Default: validate configuration without initializing the SDK or sending events.")
                return
            }
            let configuration = try PilotConfiguration(arguments: Array(CommandLine.arguments.dropFirst()),
                environment: ProcessInfo.processInfo.environment)
            let event = PilotEvent(network: configuration.network)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(event), as: UTF8.self))
            print("Region: \(configuration.region); this label is not proof of the network's location.")
            guard configuration.send else {
                print("NOT SENT: configuration checked; SDK not initialized; cloud ingestion NOT VERIFIED.")
                return
            }
            if !configuration.limitVerified {
                print("WARNING: cloud daily limit NOT VERIFIED; this uncapped pilot run was explicitly allowed.")
            }
            try send(configuration, event: event)
        } catch {
            fputs("NOT SENT / FAILED: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func send(_ configuration: PilotConfiguration, event: PilotEvent) throws {
        guard let cachePath = ProcessInfo.processInfo.environment["RAWLAB_RUM_CACHE_DIRECTORY"] else {
            throw PilotError.invalid("Run through run.sh so the parent process can clean the SDK cache on abnormal exit.")
        }
        let cache = URL(fileURLWithPath: cachePath, isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        guard let options = alibabacloud_rum_options_new() else {
            throw PilotError.invalid("SDK options allocation failed.")
        }
        defer { alibabacloud_rum_options_free(options) }
        alibabacloud_rum_options_set_config_address(options, configuration.configAddress.absoluteString)
        alibabacloud_rum_options_set_app_id(options, configuration.appID)
        alibabacloud_rum_options_set_app_name(options, "RawLab RUM Pilot")
        alibabacloud_rum_options_set_app_version(options, "0.0.0-pilot")
        alibabacloud_rum_options_set_env(options, ALIBABACLOUD_RUM_ENV_PRE)
        alibabacloud_rum_options_set_cache_path(options, cache.path)
        alibabacloud_rum_options_set_utdid(options, event.properties["run_id"]!)
        alibabacloud_rum_options_set_debug_level(options, ALIBABACLOUD_RUM_LEVEL_WARNING)
        alibabacloud_rum_options_set_auto_crash_tracking(options, 0)
        alibabacloud_rum_options_set_auto_curl_tracking(options, 0)
        alibabacloud_rum_options_set_auto_cef_tracking(options, 0)

        // SDK 关闭可能等待网络；超时会硬退出，缓存由父脚本统一清理。
        alarm(60)
        defer { alarm(0) }
        guard alibabacloud_rum_init(options) == 0 else {
            throw PilotError.invalid("SDK initialization failed; no ingestion claim is possible.")
        }
        guard let nativeEvent = alibabacloud_rum_custom_event_new(event.type, event.name) else {
            _ = alibabacloud_rum_close()
            throw PilotError.invalid("SDK event allocation failed.")
        }
        alibabacloud_rum_custom_event_set_group(nativeEvent, event.group)
        alibabacloud_rum_custom_event_set_value(nativeEvent, Double(event.value))
        for (key, value) in event.properties {
            alibabacloud_rum_custom_event_add_extra(nativeEvent, key, value)
        }
        alibabacloud_rum_custom_event_report(nativeEvent)
        sleep(15)
        guard alibabacloud_rum_close() == 0 else {
            throw PilotError.invalid("SDK shutdown failed; cloud ingestion NOT VERIFIED.")
        }
        print("ONE synthetic custom event submitted to SDK; SDK may also emit session/system metadata.")
        print("Cloud ingestion NOT VERIFIED: find this run_id in RUM Explorer before marking the route passed.")
    }
}
