import Foundation
import Security

struct MacUpdateTrust {
    let feed: URL
    let team: String
    let architecture: String
    let bundle: Bundle

    static func configured(bundle: Bundle = .main) throws -> MacUpdateTrust {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        guard bundle.bundleIdentifier == "com.rawtools.rawlab.mac",
              let raw = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let feed = URL(string: raw), feed.scheme == "https", feed.host != nil,
              feed.user == nil, feed.password == nil,
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32,
              let team = bundle.object(forInfoDictionaryKey: "RawLabUpdateTeamID") as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              bundle.object(forInfoDictionaryKey: "RawLabUpdateArchitecture") as? String == architecture,
              bundle.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true,
              bundle.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool == true,
              bundle.object(forInfoDictionaryKey: "SUSignedFeedFailureExpirationInterval") as? Int == 0 else {
            throw UpdateAdapterError(code: "configuration", detail: "")
        }
        let trust = MacUpdateTrust(feed: feed, team: team, architecture: architecture, bundle: bundle)
        try trust.validateHost()
        return trust
    }

    func validateHost() throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateAdapterError(code: "identity", detail: "")
        }
        var requirement: SecRequirement?
        let expression = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw UpdateAdapterError(code: "identity", detail: "")
        }
        // 由系统执行策略检查公证与撤销状态；不把 Info.plist 的自报标记当作公证凭据。
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        process.arguments = ["--assess", "--type", "execute", "--ignore-cache", "--no-cache", bundle.bundlePath]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        guard completed.wait(timeout: .now() + 30) == .success else {
            process.terminate()
            if completed.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            throw UpdateAdapterError(code: "notarization", detail: "System trust assessment timed out")
        }
        guard process.terminationStatus == 0 else { throw UpdateAdapterError(code: "notarization", detail: "") }
        guard FileManager.default.isWritableFile(atPath: bundle.bundleURL.deletingLastPathComponent().path) else {
            throw UpdateAdapterError(code: "permissions", detail: "")
        }
    }
}

@MainActor func makeMacUpdateAdapter() async -> UpdateAdapter {
    #if canImport(Sparkle)
    do {
        let trust = try await Task.detached { try MacUpdateTrust.configured() }.value
        return SparkleUpdateAdapter(trust: trust)
    }
    catch let error as UpdateAdapterError { return UnavailableUpdateAdapter(error.code) }
    catch { return UnavailableUpdateAdapter("identity") }
    #else
    return UnavailableUpdateAdapter("configuration")
    #endif
}
