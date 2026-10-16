import Foundation

struct RUMLocalConfiguration {
    static let disabledModules = [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13]

    let serviceID: String
    let endpoint: URL
    let workspace: String
    let deviceID: UUID
    let validationRun: UUID?

    init(environment: [String: String]) throws {
        serviceID = try Self.required(environment["RAWLAB_RUM_SERVICE_ID"], name: "RAWLAB_RUM_SERVICE_ID")
        workspace = try Self.required(environment["RAWLAB_RUM_WORKSPACE"], name: "RAWLAB_RUM_WORKSPACE")
        try Self.validateToken(serviceID, name: "RAWLAB_RUM_SERVICE_ID")
        try Self.validateToken(workspace, name: "RAWLAB_RUM_WORKSPACE")
        endpoint = try Self.endpoint(environment["RAWLAB_RUM_ENDPOINT"])

        if environment["RAWLAB_RUM_VALIDATE"] == "1" {
            guard let rawRun = environment["RAWLAB_RUM_VALIDATION_RUN"],
                  let run = UUID(uuidString: rawRun) else {
                throw RUMLocalConfigurationError.invalid("RAWLAB_RUM_VALIDATION_RUN must be a UUID for local validation")
            }
            validationRun = run
        } else {
            validationRun = nil
        }
        deviceID = validationRun ?? UUID()
    }

    private static func required(_ value: String?, name: String) throws -> String {
        guard let value, !value.isEmpty else {
            throw RUMLocalConfigurationError.invalid("Set \(name) for the explicit local RUM build")
        }
        return value
    }

    private static func validateToken(_ value: String, name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.@")
        guard value.count <= 128, value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw RUMLocalConfigurationError.invalid("\(name) contains unsupported characters")
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
            throw RUMLocalConfigurationError.invalid("RAWLAB_RUM_ENDPOINT must be the verified Shanghai SLS HTTPS base URL")
        }
        return url
    }
}

enum RUMLocalConfigurationError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}
