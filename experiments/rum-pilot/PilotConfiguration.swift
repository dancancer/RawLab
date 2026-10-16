import Foundation

struct PilotConfiguration {
    let send: Bool
    let appID: String
    let configAddress: URL
    let region: String
    let network: String
    let limitVerified: Bool

    init(arguments: [String], environment: [String: String]) throws {
        guard arguments.isEmpty || arguments == ["--check"] || arguments == ["--send"] else {
            throw PilotError.invalid("Use --check (default), --send or --help.")
        }
        send = arguments == ["--send"]
        appID = environment["RAWLAB_RUM_APP_ID"] ?? ""
        let safeID = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_@")
        guard !appID.isEmpty, appID.count <= 128,
              appID.unicodeScalars.allSatisfy(safeID.contains) else {
            throw PilotError.invalid("Set RAWLAB_RUM_APP_ID to the dedicated pilot AppID from the console.")
        }
        region = environment["RAWLAB_RUM_REGION"] ?? ""
        let mainlandRegions: Set<String> = ["cn-hangzhou", "cn-shanghai", "cn-qingdao", "cn-beijing",
            "cn-zhangjiakou", "cn-huhehaote", "cn-wulanchabu", "cn-shenzhen", "cn-heyuan",
            "cn-guangzhou", "cn-chengdu"]
        guard mainlandRegions.contains(region) else {
            throw PilotError.invalid("Set RAWLAB_RUM_REGION to the pilot's mainland China region.")
        }
        guard let components = URLComponents(string: environment["RAWLAB_RUM_CONFIG_ADDRESS"] ?? ""),
              components.scheme == "https", let host = components.host,
              host.hasSuffix(".aliyuncs.com"), components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port == nil || components.port == 443,
              let url = components.url else {
            throw PilotError.invalid("ConfigAddress must be the HTTPS aliyuncs.com URL copied from the pilot console.")
        }
        configAddress = url
        network = environment["RAWLAB_RUM_NETWORK"] ?? "not-specified"
        limitVerified = environment["RAWLAB_RUM_LIMIT_VERIFIED"] == "1"
        if send {
            guard limitVerified || environment["RAWLAB_RUM_ALLOW_UNCAPPED_PILOT"] == "1" else {
                throw PilotError.invalid("Verify the cloud daily limit, or explicitly allow this single uncapped pilot with RAWLAB_RUM_ALLOW_UNCAPPED_PILOT=1.")
            }
            guard ["china-telecom", "china-unicom", "china-mobile"].contains(network) else {
                throw PilotError.invalid("Set RAWLAB_RUM_NETWORK to the actual mainland carrier: china-telecom, china-unicom or china-mobile.")
            }
            let proxyKeys = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"]
            guard !proxyKeys.contains(where: { !(environment[$0] ?? "").isEmpty }) else {
                throw PilotError.invalid("Proxy environment variables are set; do not label a proxy route as mainland-direct.")
            }
        }
    }
}

enum PilotError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

struct PilotEvent: Encodable {
    let type = "rawlab_pilot"
    let name = "rum_pilot_probe"
    let group = "connectivity"
    let value = 1
    let properties: [String: String]

    init(network: String) {
        properties = ["run_id": UUID().uuidString, "network": network, "schema_version": "1"]
    }
}
