import Foundation

@main
struct RUMConfigurationTests {
    static func main() throws {
        let valid = [
            "RAWLAB_RUM_SERVICE_ID": "chrtja4hrt@fbde0daa498a0e32c909f",
            "RAWLAB_RUM_ENDPOINT": "https://proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai.cn-shanghai.log.aliyuncs.com",
            "RAWLAB_RUM_WORKSPACE": "default-cms-1268858473429241-cn-shanghai",
            "RAWLAB_RUM_VALIDATE": "1",
            "RAWLAB_RUM_VALIDATION_RUN": "49F70C54-2CCA-4663-B81A-35B253A826CA",
        ]
        let configuration = try RUMConfiguration(environment: valid)
        check(configuration.serviceID == valid["RAWLAB_RUM_SERVICE_ID"], "service ID is read from explicit local configuration")
        check(configuration.endpoint.absoluteString == valid["RAWLAB_RUM_ENDPOINT"], "endpoint is preserved as the verified HTTPS base URL")
        check(configuration.workspace == valid["RAWLAB_RUM_WORKSPACE"], "workspace is read from explicit local configuration")
        check(configuration.validationRun?.uuidString == valid["RAWLAB_RUM_VALIDATION_RUN"], "validation UUID is attached only for an explicit probe")
        let slashEndpoint = try RUMConfiguration(environment: valid.merging([
            "RAWLAB_RUM_ENDPOINT": valid["RAWLAB_RUM_ENDPOINT"]! + "/",
        ]) { _, new in new })
        check(slashEndpoint.endpoint.path == "/", "the Shanghai SLS base URL may carry only a root slash")

        check(RUMConfiguration.disabledModules == [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13],
              "all non-custom-event modules are disabled before SDK start")

        func rejected(_ changes: [String: String]) {
            do {
                _ = try RUMConfiguration(environment: valid.merging(changes) { _, new in new })
                fatalError("unsafe local RUM configuration was accepted")
            } catch {}
        }
        rejected(["RAWLAB_RUM_ENDPOINT": "http://proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai.cn-shanghai.log.aliyuncs.com"])
        rejected(["RAWLAB_RUM_ENDPOINT": "https://user:password@proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai.cn-shanghai.log.aliyuncs.com"])
        rejected(["RAWLAB_RUM_ENDPOINT": "https://example.attacker.test"])
        rejected(["RAWLAB_RUM_ENDPOINT": "https://proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-hangzhou.log.aliyuncs.com"])
        rejected(["RAWLAB_RUM_ENDPOINT": "https://proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai.cn-shanghai.log.aliyuncs.com/v2"])
        rejected(["RAWLAB_RUM_VALIDATE": "1", "RAWLAB_RUM_VALIDATION_RUN": "not-a-uuid"])

        let normal = try RUMConfiguration(environment: valid.merging([
            "RAWLAB_RUM_VALIDATE": "0",
            "RAWLAB_RUM_VALIDATION_RUN": "",
        ]) { _, new in new })
        check(normal.validationRun == nil, "normal local builds do not add a validation marker")
        check(configuration.environment == .local, "environment-supplied targets are local validation")

        // 正式配置：上报目标写死，环境变量只能打开合成验证探针
        let production = try RUMConfiguration.production(environment: [:])
        check(production.environment == .production, "release builds report to the production environment")
        check(production.serviceID == "chrtja4hrt@fbde0daa498a0e32c909f", "release builds use the iOS app")
        check(production.workspace == valid["RAWLAB_RUM_WORKSPACE"], "release builds use the Shanghai workspace")
        check(production.endpoint.absoluteString == valid["RAWLAB_RUM_ENDPOINT"], "release builds use the verified endpoint")
        check(production.validationRun == nil, "ordinary release launches carry no validation marker")
        let redirected = try RUMConfiguration.production(environment: valid.merging([
            "RAWLAB_RUM_SERVICE_ID": "attacker@1", "RAWLAB_RUM_ENDPOINT": "https://example.attacker.test",
        ]) { _, new in new })
        check(redirected.serviceID == production.serviceID && redirected.endpoint == production.endpoint,
              "environment variables cannot redirect release reporting")
        check(redirected.validationRun?.uuidString == valid["RAWLAB_RUM_VALIDATION_RUN"], "release probe carries the synthetic marker")
        do {
            _ = try RUMConfiguration.production(environment: ["RAWLAB_RUM_VALIDATE": "1", "RAWLAB_RUM_VALIDATION_RUN": "x"])
            fatalError("release probe accepted an arbitrary marker")
        } catch {}
        print("PASS: iOS production and local configuration, module policy and validation marker")
    }

    private static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
    }
}
