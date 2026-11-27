import Foundation
import XCTest
@testable import RawLabKit

final class RUMPCConfigurationTests: XCTestCase {
    func testLocalConfigurationValidation() throws {
        let valid = [
            "RAWLAB_RUM_APP_ID": "test@123",
            "RAWLAB_RUM_CONFIG_ADDRESS": "https://proj-test.cn-shanghai.log.aliyuncs.com/rum/web/v2",
        ]
        let configuration = try RUMPCConfiguration(environment: valid)
        XCTAssertNil(configuration.validationRun)
        for address in [
            "http://proj-test.cn-shanghai.log.aliyuncs.com/rum/web/v2",
            "https://example.com/rum/web/v2",
            "https://proj-test.cn-shanghai.log.aliyuncs.com/rum/web/v2?token=x",
            "https://a@proj-test.cn-shanghai.log.aliyuncs.com/rum/web/v2",
        ] {
            var values = valid
            values["RAWLAB_RUM_CONFIG_ADDRESS"] = address
            XCTAssertThrowsError(try RUMPCConfiguration(environment: values), "accepted invalid address: \(address)")
        }
        var values = valid
        values["RAWLAB_RUM_VALIDATION_RUN"] = "not-an-id"
        XCTAssertThrowsError(try RUMPCConfiguration(environment: values), "accepted arbitrary validation data")
        XCTAssertEqual(configuration.environment, .local, "environment-supplied configuration is local validation")
    }

    func testProductionConfigurationRestrictions() throws {
        let valid = [
            "RAWLAB_RUM_APP_ID": "test@123",
            "RAWLAB_RUM_CONFIG_ADDRESS": "https://proj-test.cn-shanghai.log.aliyuncs.com/rum/web/v2",
        ]
        // 正式配置：写死在应用里，环境变量只能追加合成验证标记，不能改上报目标
        let production = try RUMPCConfiguration.production(environment: valid)
        XCTAssertEqual(production.environment, .production)
        XCTAssertEqual(production.appID, "chrtja4hrt@50261ae2de76a14", "production uses the macOS app")
        XCTAssertEqual(production.configAddress, RUMPCConfiguration.productionConfigAddress)
        XCTAssertNil(production.validationRun)
        let marker = UUID().uuidString
        let probe = try RUMPCConfiguration.production(environment: ["RAWLAB_RUM_VALIDATION_RUN": marker])
        XCTAssertEqual(probe.validationRun, marker, "production probe carries the synthetic marker")
        XCTAssertThrowsError(
            try RUMPCConfiguration.production(environment: ["RAWLAB_RUM_VALIDATION_RUN": "x"]),
            "accepted arbitrary marker"
        )
    }
}
