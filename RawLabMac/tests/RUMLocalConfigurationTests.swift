import Foundation

@main struct RUMLocalConfigurationTests {
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
        print("PASS: local PC configuration restricts Shanghai HTTPS and synthetic marker")
    }
}
