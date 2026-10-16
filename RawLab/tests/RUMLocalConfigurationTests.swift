import Foundation

@main
struct RUMLocalConfigurationTests {
    static func main() throws {
        let valid = [
            "RAWLAB_RUM_SERVICE_ID": "chrtja4hrt@fbde0daa498a0e32c909f",
            "RAWLAB_RUM_ENDPOINT": "https://proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai.cn-shanghai.log.aliyuncs.com",
            "RAWLAB_RUM_WORKSPACE": "default-cms-1268858473429241-cn-shanghai",
            "RAWLAB_RUM_VALIDATE": "1",
            "RAWLAB_RUM_VALIDATION_RUN": "49F70C54-2CCA-4663-B81A-35B253A826CA",
        ]
        let configuration = try RUMLocalConfiguration(environment: valid)
        check(configuration.serviceID == valid["RAWLAB_RUM_SERVICE_ID"], "service ID is read from explicit local configuration")
        check(configuration.endpoint.absoluteString == valid["RAWLAB_RUM_ENDPOINT"], "endpoint is preserved as the verified HTTPS base URL")
        check(configuration.workspace == valid["RAWLAB_RUM_WORKSPACE"], "workspace is read from explicit local configuration")
        check(configuration.validationRun?.uuidString == valid["RAWLAB_RUM_VALIDATION_RUN"], "validation UUID is attached only for an explicit probe")
        let slashEndpoint = try RUMLocalConfiguration(environment: valid.merging([
            "RAWLAB_RUM_ENDPOINT": valid["RAWLAB_RUM_ENDPOINT"]! + "/",
        ]) { _, new in new })
        check(slashEndpoint.endpoint.path == "/", "the Shanghai SLS base URL may carry only a root slash")

        check(RUMLocalConfiguration.disabledModules == [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13],
              "all non-custom-event modules are disabled before SDK start")

        func rejected(_ changes: [String: String]) {
            do {
                _ = try RUMLocalConfiguration(environment: valid.merging(changes) { _, new in new })
                fatalError("unsafe local RUM configuration was accepted")
            } catch {}
        }
        rejected(["RAWLAB_RUM_ENDPOINT": "http://proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai.cn-shanghai.log.aliyuncs.com"])
        rejected(["RAWLAB_RUM_ENDPOINT": "https://user:password@proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai.cn-shanghai.log.aliyuncs.com"])
        rejected(["RAWLAB_RUM_ENDPOINT": "https://example.attacker.test"])
        rejected(["RAWLAB_RUM_ENDPOINT": "https://proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-hangzhou.log.aliyuncs.com"])
        rejected(["RAWLAB_RUM_ENDPOINT": "https://proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai.cn-shanghai.log.aliyuncs.com/v2"])
        rejected(["RAWLAB_RUM_VALIDATE": "1", "RAWLAB_RUM_VALIDATION_RUN": "not-a-uuid"])

        let normal = try RUMLocalConfiguration(environment: valid.merging([
            "RAWLAB_RUM_VALIDATE": "0",
            "RAWLAB_RUM_VALIDATION_RUN": "",
        ]) { _, new in new })
        check(normal.validationRun == nil, "normal local builds do not add a validation marker")
        print("PASS: iOS local configuration, module policy and validation marker")
    }

    private static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
    }
}
