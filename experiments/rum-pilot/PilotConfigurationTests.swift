import Foundation

@main
struct PilotConfigurationTests {
    static func main() throws {
        let environment = [
            "RAWLAB_RUM_APP_ID": "pilot-app-id",
            "RAWLAB_RUM_CONFIG_ADDRESS": "https://example.cn-hangzhou.rum.aliyuncs.com",
            "RAWLAB_RUM_REGION": "cn-hangzhou",
        ]
        let checked = try PilotConfiguration(arguments: [], environment: environment)
        precondition(!checked.send)
        precondition(checked.region == "cn-hangzhou")
        precondition(checked.appID == "pilot-app-id")
        let consoleID = try PilotConfiguration(arguments: [], environment: environment.merging([
            "RAWLAB_RUM_APP_ID": "pilot-app@0123456789abcdef",
        ]) { _, new in new })
        precondition(consoleID.appID == "pilot-app@0123456789abcdef")

        func rejected(_ arguments: [String] = [], _ changes: [String: String]) {
            do {
                _ = try PilotConfiguration(arguments: arguments,
                    environment: environment.merging(changes) { _, new in new })
                preconditionFailure("Unsafe pilot configuration was accepted")
            } catch {}
        }

        rejected([], ["RAWLAB_RUM_APP_ID": ""])
        rejected([], ["RAWLAB_RUM_APP_ID": "photo/private-path"])
        rejected([], ["RAWLAB_RUM_CONFIG_ADDRESS": "http://example.cn-hangzhou.rum.aliyuncs.com"])
        rejected([], ["RAWLAB_RUM_CONFIG_ADDRESS": "https://example.cn-hangzhou.rum.aliyuncs.com.attacker.test"])
        rejected([], ["RAWLAB_RUM_CONFIG_ADDRESS": "https://user:password@example.cn-hangzhou.rum.aliyuncs.com"])
        rejected([], ["RAWLAB_RUM_CONFIG_ADDRESS": "https://example.cn-hangzhou.rum.aliyuncs.com/#secret"])
        rejected([], ["RAWLAB_RUM_CONFIG_ADDRESS": "https://example.cn-hangzhou.rum.aliyuncs.com/?token=secret"])
        rejected([], ["RAWLAB_RUM_CONFIG_ADDRESS": "https://example.cn-hangzhou.rum.aliyuncs.com/?"])
        rejected([], ["RAWLAB_RUM_REGION": "cn-hongkong"])
        rejected(["--unknown"], [:])
        rejected(["--send"], [:])
        rejected(["--send"], ["RAWLAB_RUM_LIMIT_VERIFIED": "1"])
        rejected(["--send"], ["RAWLAB_RUM_ALLOW_UNCAPPED_PILOT": "1"])
        rejected(["--send"], ["RAWLAB_RUM_ALLOW_UNCAPPED_PILOT": "0", "RAWLAB_RUM_NETWORK": "china-telecom"])

        let approved = environment.merging([
            "RAWLAB_RUM_LIMIT_VERIFIED": "1",
            "RAWLAB_RUM_NETWORK": "china-telecom",
        ]) { _, new in new }
        let sending = try PilotConfiguration(arguments: ["--send"], environment: approved)
        precondition(sending.send)
        precondition(sending.network == "china-telecom")
        precondition(sending.limitVerified)
        let uncapped = environment.merging([
            "RAWLAB_RUM_ALLOW_UNCAPPED_PILOT": "1",
            "RAWLAB_RUM_NETWORK": "china-telecom",
        ]) { _, new in new }
        let uncappedSending = try PilotConfiguration(arguments: ["--send"], environment: uncapped)
        precondition(uncappedSending.send)
        precondition(!uncappedSending.limitVerified)
        for budget in [approved, uncapped] {
            do {
                _ = try PilotConfiguration(arguments: ["--send"],
                    environment: budget.merging(["HTTPS_PROXY": "http://127.0.0.1:7890"]) { _, new in new })
                preconditionFailure("Proxy route was accepted as a mainland-direct pilot")
            } catch {}
        }

        let payload = PilotEvent(network: "china-telecom")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]
        precondition(object["name"] as? String == "rum_pilot_probe")
        precondition(object["value"] as? Int == 1)
        let properties = object["properties"] as! [String: String]
        precondition(Set(properties.keys) == ["run_id", "network", "schema_version"])
        precondition(UUID(uuidString: properties["run_id"]!) != nil)
        precondition(properties["schema_version"] == "1")
        precondition(properties["network"] == "china-telecom")
        print("PASS: dry run, explicit budget gates, HTTPS/region validation, proxy refusal and fixed event payload")
    }
}
