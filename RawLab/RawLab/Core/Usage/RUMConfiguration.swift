import Foundation

// ----------------------------------------------------------------------------
//  iOS 版 RUM 接入参数
//  - 正式：上报目标写死在应用里；环境变量只能打开合成验证探针（RAWLAB_RUM_VALIDATE=1 + UUID 标记）
//  - 本地验证构建：目标全部来自环境变量，只接受上海 SLS 的 HTTPS 地址
//  ServiceId、Workspace、Endpoint 是公开接入参数，不是凭证
// ----------------------------------------------------------------------------
struct RUMConfiguration {
    enum Environment { case production, local }
    static let disabledModules = [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13]
    static let productionServiceID = "chrtja4hrt@fbde0daa498a0e32c909f"
    static let productionWorkspace = "default-cms-1268858473429241-cn-shanghai"
    static let productionEndpoint =
        "https://proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai.cn-shanghai.log.aliyuncs.com"

    let serviceID: String
    let endpoint: URL
    let workspace: String
    let environment: Environment
    let validationRun: UUID?

    init(environment: [String: String]) throws {
        try self.init(serviceID: environment["RAWLAB_RUM_SERVICE_ID"], workspace: environment["RAWLAB_RUM_WORKSPACE"],
                      endpoint: environment["RAWLAB_RUM_ENDPOINT"], environment: .local, probe: environment)
    }

    static func production(environment: [String: String]) throws -> RUMConfiguration {
        try RUMConfiguration(serviceID: productionServiceID, workspace: productionWorkspace,
                             endpoint: productionEndpoint, environment: .production, probe: environment)
    }

    private init(serviceID: String?, workspace: String?, endpoint: String?,
                 environment: Environment, probe: [String: String]) throws {
        self.serviceID = try Self.required(serviceID, name: "RAWLAB_RUM_SERVICE_ID")
        self.workspace = try Self.required(workspace, name: "RAWLAB_RUM_WORKSPACE")
        try Self.validateToken(self.serviceID, name: "RAWLAB_RUM_SERVICE_ID")
        try Self.validateToken(self.workspace, name: "RAWLAB_RUM_WORKSPACE")
        self.endpoint = try Self.endpoint(endpoint)
        self.environment = environment
        validationRun = try Self.validationRun(probe)
    }

    private static func validationRun(_ environment: [String: String]) throws -> UUID? {
        guard environment["RAWLAB_RUM_VALIDATE"] == "1" else { return nil }
        guard let raw = environment["RAWLAB_RUM_VALIDATION_RUN"], let run = UUID(uuidString: raw) else {
            throw RUMConfigurationError.invalid("RAWLAB_RUM_VALIDATION_RUN must be a UUID for RUM validation")
        }
        return run
    }

    private static func required(_ value: String?, name: String) throws -> String {
        guard let value, !value.isEmpty else {
            throw RUMConfigurationError.invalid("Set \(name) for the explicit local RUM build")
        }
        return value
    }

    private static func validateToken(_ value: String, name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.@")
        guard value.count <= 128, value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw RUMConfigurationError.invalid("\(name) contains unsupported characters")
        }
    }

    private static func endpoint(_ value: String?) throws -> URL {
        guard let raw = value,
              let components = URLComponents(string: raw),
              components.scheme == "https",
              let host = components.host,
              host.hasPrefix("proj-"),
              host.hasSuffix(".cn-shanghai.log.aliyuncs.com"),
              host.count > "proj-".count + ".cn-shanghai.log.aliyuncs.com".count,
              components.path.isEmpty || components.path == "/",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.port == nil || components.port == 443,
              let url = components.url else {
            throw RUMConfigurationError.invalid("RAWLAB_RUM_ENDPOINT must be the verified Shanghai SLS HTTPS base URL")
        }
        return url
    }
}

enum RUMConfigurationError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}
