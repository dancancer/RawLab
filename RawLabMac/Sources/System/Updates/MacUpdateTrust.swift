import Foundation
import Security
import CryptoKit

enum MacUpdateTrustMode: Equatable {
    case certificate(String), developerID(String)

    static func configured(certificate: String?, team: String?) throws -> Self {
        let certificate = certificate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let team = team?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if team.isEmpty, certificate.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil {
            return .certificate(certificate.lowercased())
        }
        if certificate.isEmpty, team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil {
            return .developerID(team)
        }
        throw UpdateAdapterError(code: "configuration", detail: "")
    }
}

struct MacUpdateTrust {
    let feed: URL
    let mode: MacUpdateTrustMode
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
              bundle.object(forInfoDictionaryKey: "RawLabUpdateArchitecture") as? String == architecture,
              bundle.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true,
              bundle.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool == true,
              bundle.object(forInfoDictionaryKey: "SUSignedFeedFailureExpirationInterval") as? Int == 0 else {
            throw UpdateAdapterError(code: "configuration", detail: "")
        }
        let mode = try MacUpdateTrustMode.configured(
            certificate: bundle.object(forInfoDictionaryKey: "RawLabUpdateCertificateSHA256") as? String,
            team: bundle.object(forInfoDictionaryKey: "RawLabUpdateTeamID") as? String)
        let trust = MacUpdateTrust(feed: feed, mode: mode, architecture: architecture, bundle: bundle)
        // 普通启动只读取签名身份；完整代码校验与系统策略检查留到检查更新及升级首启。
        _ = try trust.signingRequirement(for: bundle)
        try trust.validateLocation()
        return trust
    }

    private func signingRequirement(for bundle: Bundle) throws -> (SecStaticCode, SecRequirement) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateAdapterError(code: "identity", detail: "")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any],
              let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { throw UpdateAdapterError(code: "identity", detail: "") }
        let expression: String
        switch mode {
        case .certificate(let expected):
            let bytes = SecCertificateCopyData(leaf) as Data
            guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expected else {
                throw UpdateAdapterError(code: "identity", detail: "Signing certificate does not match")
            }
            // Security 的证书要求使用 SHA-1；配置身份先由完整证书的 SHA-256 固定。
            let fingerprint = Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            expression = "certificate leaf = H\"\(fingerprint)\""
        case .developerID(let team):
            guard information[kSecCodeInfoTeamIdentifier as String] as? String == team else {
                throw UpdateAdapterError(code: "identity", detail: "")
            }
            expression = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateAdapterError(code: "identity", detail: "")
        }
        return (code, requirement)
    }

    private func validateLocation() throws {
        guard FileManager.default.isWritableFile(atPath: bundle.bundleURL.deletingLastPathComponent().path) else {
            throw UpdateAdapterError(code: "permissions", detail: "")
        }
    }

    func validateHost() throws {
        try validateCode(in: bundle)
        try validateLocation()
    }

    // 更新包必须符合正在运行版本的信任配置，不能自行声明新的固定证书。
    func validateCode(in bundle: Bundle) throws {
        let (code, requirement) = try signingRequirement(for: bundle)
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw UpdateAdapterError(code: "identity", detail: "")
        }
        guard case .developerID = mode else { return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        process.arguments = ["--assess", "--type", "execute", "--ignore-cache", "--no-cache", bundle.bundlePath]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do { try process.run() }
        catch { throw UpdateAdapterError(code: "trust_temporary", detail: error.localizedDescription) }
        guard completed.wait(timeout: .now() + 30) == .success else {
            process.terminate()
            if completed.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            throw UpdateAdapterError(code: "trust_temporary", detail: "System trust assessment timed out")
        }
        guard process.terminationStatus == 0 else {
            throw UpdateAdapterError(code: process.terminationStatus == 3 ? "notarization" : "trust_temporary",
                detail: "System trust assessment exited with status \(process.terminationStatus)")
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
