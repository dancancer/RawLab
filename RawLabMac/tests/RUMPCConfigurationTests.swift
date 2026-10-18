import Foundation

@main struct RUMPCConfigurationTests {
    static func main() throws {
        let valid = ["RAWLAB_RUM_APP_ID": "test@123", "RAWLAB_RUM_CONFIG_ADDRESS":
            "https://proj-test.cn-shanghai.log.aliyuncs.com/rum/web/v2"]
        let configuration = try RUMPCConfiguration(environment: valid)
        precondition(configuration.validationRun == nil)
        for address in ["http://proj-test.cn-shanghai.log.aliyuncs.com/rum/web/v2",
                        "https://example.com/rum/web/v2", "https://proj-test.cn-shanghai.log.aliyuncs.com/rum/web/v2?token=x",
                        "https://a@proj-test.cn-shanghai.log.aliyuncs.com/rum/web/v2"] {
            var values = valid; values["RAWLAB_RUM_CONFIG_ADDRESS"] = address
            do { _ = try RUMPCConfiguration(environment: values); fatalError("accepted invalid address") }
            catch { }
        }
        var values = valid; values["RAWLAB_RUM_VALIDATION_RUN"] = "not-an-id"
        do { _ = try RUMPCConfiguration(environment: values); fatalError("accepted arbitrary validation data") }
        catch { }
        precondition(configuration.environment == .local, "environment-supplied configuration is local validation")

        // 正式配置：写死在应用里，环境变量只能追加合成验证标记，不能改上报目标
        let production = try RUMPCConfiguration.production(environment: valid)
        precondition(production.environment == .production)
        precondition(production.appID == "chrtja4hrt@50261ae2de76a14", "production uses the macOS app")
        precondition(production.configAddress == RUMPCConfiguration.productionConfigAddress)
        precondition(production.validationRun == nil)
        let marker = UUID().uuidString
        let probe = try RUMPCConfiguration.production(environment: ["RAWLAB_RUM_VALIDATION_RUN": marker])
        precondition(probe.validationRun == marker, "production probe carries the synthetic marker")
        do { _ = try RUMPCConfiguration.production(environment: ["RAWLAB_RUM_VALIDATION_RUN": "x"]); fatalError("accepted arbitrary marker") }
        catch { }
        print("PASS: PC configuration: production target is fixed, local validation restricts Shanghai HTTPS and synthetic marker")
    }
}
