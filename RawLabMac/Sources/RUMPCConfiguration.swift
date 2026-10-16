import Foundation

struct RUMPCConfiguration {
    let appID: String
    let configAddress: String
    let validationRun: String?
    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let id = environment["RAWLAB_RUM_APP_ID"],
              id.range(of: "^[A-Za-z0-9@_-]{3,100}$", options: .regularExpression) != nil,
              let address = environment["RAWLAB_RUM_CONFIG_ADDRESS"],
              let url = URLComponents(string: address), url.scheme == "https",
              let host = url.host, host.hasSuffix(".cn-shanghai.log.aliyuncs.com"),
              host.hasPrefix("proj-"), url.path == "/rum/web/v2",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { throw CocoaError(.coderInvalidValue) }
        let marker = environment["RAWLAB_RUM_VALIDATION_RUN"]
        if let marker, UUID(uuidString: marker) == nil { throw CocoaError(.coderInvalidValue) }
        appID = id; configAddress = address; validationRun = marker
    }
}
