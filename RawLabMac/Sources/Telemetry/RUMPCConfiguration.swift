import Foundation

// ----------------------------------------------------------------------------
//  macOS 版 RUM 接入参数
//  - 正式：上报目标写死在应用里，环境变量只能追加合成验证标记
//  - 本地验证：目标全部来自环境变量，只接受上海 SLS 的 HTTPS 地址
//  AppID 与 ConfigAddress 是公开接入参数，不是凭证
// ----------------------------------------------------------------------------
struct RUMPCConfiguration {
    enum Environment { case production, local }
    static let productionAppID = "chrtja4hrt@50261ae2de76a14"
    static let productionConfigAddress =
        "https://proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai.cn-shanghai.log.aliyuncs.com/rum/web/v2"

    let appID: String
    let configAddress: String
    let validationRun: String?
    let environment: Environment

    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let id = environment["RAWLAB_RUM_APP_ID"],
              id.range(of: "^[A-Za-z0-9@_-]{3,100}$", options: .regularExpression) != nil,
              let address = environment["RAWLAB_RUM_CONFIG_ADDRESS"],
              let url = URLComponents(string: address), url.scheme == "https",
              let host = url.host, host.hasSuffix(".cn-shanghai.log.aliyuncs.com"),
              host.hasPrefix("proj-"), url.path == "/rum/web/v2",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { throw CocoaError(.coderInvalidValue) }
        try self.init(appID: id, configAddress: address, environment: .local,
                      validationRun: environment["RAWLAB_RUM_VALIDATION_RUN"])
    }

    static func production(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        try Self(appID: productionAppID, configAddress: productionConfigAddress, environment: .production,
                 validationRun: environment["RAWLAB_RUM_VALIDATION_RUN"])
    }

    private init(appID: String, configAddress: String, environment: Environment, validationRun: String?) throws {
        if let validationRun, UUID(uuidString: validationRun) == nil { throw CocoaError(.coderInvalidValue) }
        self.appID = appID; self.configAddress = configAddress
        self.environment = environment; self.validationRun = validationRun
    }
}
