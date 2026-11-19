import Foundation

// ----------------------------------------------------------------------------
//  iOS 版 RUM 接入参数
// ----------------------------------------------------------------------------
public struct RUMConfiguration: Sendable {
    public enum Environment: Sendable { case production, local }
    public static let disabledModules = [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13]
    public static let productionServiceID = "chrtja4hrt@fbde0daa498a0e32c909f"
    public static let productionWorkspace = "default-cms-1268858473429241-cn-shanghai"
    public static let productionEndpoint =
        "https://proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai.cn-shanghai.log.aliyuncs.com"

    public let serviceID: String
    public let endpoint: URL
    public let workspace: String
    public let environment: Environment
    public let validationRun: UUID?

    public init(environment: [String: String]) throws {
        try self.init(serviceID: environment["RAWLAB_RUM_SERVICE_ID"], workspace: environment["RAWLAB_RUM_WORKSPACE"],
                      endpoint: environment["RAWLAB_RUM_ENDPOINT"], environment: .local, probe: environment)
    }

    public static func production(environment: [String: String]) throws -> RUMConfiguration {
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

public enum RUMConfigurationError: LocalizedError, Sendable {
    case invalid(String)

    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

// ----------------------------------------------------------------------------
//  macOS 版 RUM 接入参数
// ----------------------------------------------------------------------------
public struct RUMPCConfiguration: Sendable {
    public enum Environment: Sendable { case production, local }
    public static let productionAppID = "chrtja4hrt@50261ae2de76a14"
    public static let productionConfigAddress =
        "https://proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai.cn-shanghai.log.aliyuncs.com/rum/web/v2"

    public let appID: String
    public let configAddress: String
    public let validationRun: String?
    public let environment: Environment

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
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

    public static func production(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        try Self(appID: productionAppID, configAddress: productionConfigAddress, environment: .production,
                 validationRun: environment["RAWLAB_RUM_VALIDATION_RUN"])
    }

    private init(appID: String, configAddress: String, environment: Environment, validationRun: String?) throws {
        if let validationRun, UUID(uuidString: validationRun) == nil { throw CocoaError(.coderInvalidValue) }
        self.appID = appID; self.configAddress = configAddress
        self.environment = environment; self.validationRun = validationRun
    }
}
