import CryptoKit
import Foundation
import Security
#if canImport(RawLabCameraSSH)
import RawLabCameraSSH
#endif

struct CameraSSHHostProbe: Equatable {
    let host: String
    let port: UInt16
    let fingerprint: String
    let keyType: String
}

struct CameraAccessAuthRecord: Equatable {
    let user: String
    let password: String
    let fingerprint: String
}

protocol CameraSSHTunneling: AnyObject {
    var hostProbe: CameraSSHHostProbe { get }
    func openChannel(port: UInt16, allowedPorts: Set<UInt16>, timeout: TimeInterval) throws -> CameraByteChannel
    func close()
}

protocol CameraSSHTransporting: AnyObject {
    func probeHostKey(host: String, port: UInt16, timeout: TimeInterval) throws -> CameraSSHHostProbe
    func connect(
        host: String,
        port: UInt16,
        username: String,
        password: String,
        expectedFingerprint: String,
        timeout: TimeInterval
    ) throws -> CameraSSHTunneling
}

protocol CameraAccessAuthStoring: AnyObject {
    func load(cameraID: String) -> CameraAccessAuthRecord?
    @discardableResult
    func save(cameraID: String, record: CameraAccessAuthRecord) -> Bool
    func delete(cameraID: String)
}

struct CameraAuthPromptInfo: Equatable {
    let host: String
    let port: UInt16
    let fingerprint: String
    let keyType: String
    let initialUser: String
    let fingerprintChanged: Bool
    let hasSavedCredentials: Bool
    let error: CameraProtocolError?
}

enum CameraAuthResolution {
    case directSuccess(SonyCameraSession)
    case sshConnected(session: SonyCameraSession, tunnel: CameraSSHTunneling)
    case promptAuth(CameraAuthPromptInfo)
    case failed(Error)
}

func normalizeCameraSSHSHA256Fingerprint(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("SHA256:") else { return nil }
    let payload = String(trimmed.dropFirst("SHA256:".count))
    guard (43...44).contains(payload.count) else { return nil }
    let unpadded = payload.hasSuffix("=") ? String(payload.dropLast()) : payload
    guard unpadded.count == 43,
          !unpadded.contains(where: { $0.isWhitespace || $0 == "-" || $0 == "_" }),
          let decoded = Data(base64Encoded: unpadded + "="),
          decoded.count == 32 else {
        return nil
    }
    var canonical = decoded.base64EncodedString()
    while canonical.hasSuffix("=") { canonical.removeLast() }
    guard canonical == unpadded else { return nil }
    return "SHA256:" + canonical
}

func constantTimeCameraFingerprintEquals(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8)
    let b = Array(rhs.utf8)
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<a.count { diff |= a[i] ^ b[i] }
    return diff == 0
}

final class KeychainCameraAccessAuthStore: CameraAccessAuthStoring {
    private let service = "com.rawlab.camera-access-auth"

    private struct StoredPayload: Codable {
        let user: String
        let password: String
        let fingerprint: String
    }

    private func accountKey(for cameraID: String) -> String? {
        let trimmed = cameraID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : "cam:" + trimmed
    }

    func load(cameraID: String) -> CameraAccessAuthRecord? {
        guard let account = accountKey(for: cameraID) else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let decoded = try? JSONDecoder().decode(StoredPayload.self, from: data),
              let normalized = normalizeCameraSSHSHA256Fingerprint(decoded.fingerprint) else {
            return nil
        }
        let user = decoded.user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !decoded.password.isEmpty else { return nil }
        return CameraAccessAuthRecord(user: user, password: decoded.password, fingerprint: normalized)
    }

    @discardableResult
    func save(cameraID: String, record: CameraAccessAuthRecord) -> Bool {
        guard let account = accountKey(for: cameraID),
              let normalized = normalizeCameraSSHSHA256Fingerprint(record.fingerprint) else {
            return false
        }
        let trimmedUser = record.user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty, !record.password.isEmpty,
              let payload = try? JSONEncoder().encode(
                  StoredPayload(user: trimmedUser, password: record.password, fingerprint: normalized)
              ) else {
            return false
        }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: payload,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus != errSecItemNotFound {
            SecItemDelete(baseQuery as CFDictionary)
        }
        var addQuery = baseQuery
        attributes.forEach { addQuery[$0.key] = $0.value }
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    func delete(cameraID: String) {
        guard let account = accountKey(for: cameraID) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

func resolveCameraAccessAuth(
    host: String,
    cameraID: String,
    authStore: CameraAccessAuthStoring,
    probeSSH: (String, UInt16) throws -> CameraSSHHostProbe,
    connectSSH: (String, UInt16, String, String, String) throws -> CameraSSHTunneling,
    openOverTunnel: (CameraSSHTunneling) throws -> SonyCameraSession,
    tryDirect: () throws -> SonyCameraSession,
    sshPort: UInt16 = 22
) -> CameraAuthResolution {
    let saved = cameraID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? nil
        : authStore.load(cameraID: cameraID)

    if let saved {
        if let probe = try? probeSSH(host, sshPort) {
            let savedFingerprint = normalizeCameraSSHSHA256Fingerprint(saved.fingerprint)
            guard let savedFingerprint,
                  constantTimeCameraFingerprintEquals(savedFingerprint, probe.fingerprint) else {
                return .promptAuth(
                    CameraAuthPromptInfo(
                        host: probe.host,
                        port: probe.port,
                        fingerprint: probe.fingerprint,
                        keyType: probe.keyType,
                        initialUser: saved.user,
                        fingerprintChanged: true,
                        hasSavedCredentials: true,
                        error: nil
                    )
                )
            }
            var openedTunnel: CameraSSHTunneling?
            do {
                let tunnel = try connectSSH(host, sshPort, saved.user, saved.password, probe.fingerprint)
                openedTunnel = tunnel
                let session = try openOverTunnel(tunnel)
                return .sshConnected(session: session, tunnel: tunnel)
            } catch CameraProtocolError.sshAuthenticationFailed {
                openedTunnel?.close()
                return .promptAuth(
                    CameraAuthPromptInfo(
                        host: probe.host,
                        port: probe.port,
                        fingerprint: probe.fingerprint,
                        keyType: probe.keyType,
                        initialUser: saved.user,
                        fingerprintChanged: false,
                        hasSavedCredentials: true,
                        error: .sshAuthenticationFailed
                    )
                )
            } catch let mismatch as CameraProtocolError where {
                if case .sshFingerprintMismatch = mismatch { return true }
                return false
            }() {
                openedTunnel?.close()
                return .promptAuth(
                    CameraAuthPromptInfo(
                        host: probe.host,
                        port: probe.port,
                        fingerprint: probe.fingerprint,
                        keyType: probe.keyType,
                        initialUser: saved.user,
                        fingerprintChanged: true,
                        hasSavedCredentials: true,
                        error: mismatch
                    )
                )
            } catch CameraProtocolError.sshUnsupportedAuthMethod {
                openedTunnel?.close()
                return .failed(CameraProtocolError.sshUnsupportedAuthMethod)
            } catch {
                openedTunnel?.close()
                return .failed(error)
            }
        }
    }

    do {
        return .directSuccess(try tryDirect())
    } catch CameraProtocolError.localNetworkDenied {
        return .failed(CameraProtocolError.localNetworkDenied)
    } catch CameraProtocolError.cancelled {
        return .failed(CameraProtocolError.cancelled)
    } catch CameraProtocolError.unsupported(let detail) {
        return .failed(CameraProtocolError.unsupported(detail))
    } catch let directError {
        do {
            let probe = try probeSSH(host, sshPort)
            return .promptAuth(
                CameraAuthPromptInfo(
                    host: probe.host,
                    port: probe.port,
                    fingerprint: probe.fingerprint,
                    keyType: probe.keyType,
                    initialUser: "",
                    fingerprintChanged: false,
                    hasSavedCredentials: false,
                    error: nil
                )
            )
        } catch CameraProtocolError.localNetworkDenied {
            return .failed(CameraProtocolError.localNetworkDenied)
        } catch CameraProtocolError.cancelled {
            return .failed(CameraProtocolError.cancelled)
        } catch {
            return .failed(directError)
        }
    }
}

#if canImport(RawLabCameraSSH)
private final class NIOCameraSSHByteChannel: CameraByteChannel {
    private let direct: RawLabSSHDirectChannel

    init(direct: RawLabSSHDirectChannel) {
        self.direct = direct
    }

    func read(_ count: Int) throws -> Data {
        do {
            return try direct.read(count, maxBudget: CameraWire.dataLimit)
        } catch let error as RawLabSSHError {
            throw CameraAccessAuthErrorMapper.map(error)
        }
    }

    func write(_ data: Data) throws {
        do {
            try direct.write(data)
        } catch let error as RawLabSSHError {
            throw CameraAccessAuthErrorMapper.map(error)
        }
    }

    func close() {
        direct.close()
    }

    func beginEventLoop() {
        direct.beginEventLoop()
    }
}

private final class NIOCameraSSHTunnelAdapter: CameraSSHTunneling {
    private let tunnel: RawLabSSHTunnel
    let hostProbe: CameraSSHHostProbe

    init(tunnel: RawLabSSHTunnel) {
        self.tunnel = tunnel
        self.hostProbe = CameraSSHHostProbe(
            host: tunnel.hostProbe.host,
            port: tunnel.hostProbe.port,
            fingerprint: tunnel.hostProbe.fingerprint,
            keyType: tunnel.hostProbe.keyType
        )
    }

    func openChannel(port: UInt16, allowedPorts: Set<UInt16>, timeout: TimeInterval) throws -> CameraByteChannel {
        do {
            let direct = try tunnel.openDirectTCPIP(port: port, allowedPorts: allowedPorts, timeout: timeout)
            return NIOCameraSSHByteChannel(direct: direct)
        } catch let error as RawLabSSHError {
            throw CameraAccessAuthErrorMapper.map(error)
        }
    }

    func close() {
        tunnel.close()
    }
}

enum CameraAccessAuthErrorMapper {
    static func map(_ error: RawLabSSHError) -> CameraProtocolError {
        switch error {
        case .invalidEndpoint(let message):
            return .invalid(message)
        case .fingerprintMismatch(let expected, let actual, let keyType):
            return .sshFingerprintMismatch(expected: expected, actual: actual, keyType: keyType)
        case .authenticationFailed:
            return .sshAuthenticationFailed
        case .unsupportedAuthenticationMethod:
            return .sshUnsupportedAuthMethod
        case .localNetworkDenied:
            return .localNetworkDenied
        case .connectionRefused:
            return .connectionRefused
        case .timeout:
            return .timeout
        case .disconnected, .channelOpenFailed:
            return .disconnected
        case .cancelled:
            return .cancelled
        }
    }
}

final class NIOCameraSSHTransport: CameraSSHTransporting {
    func probeHostKey(host: String, port: UInt16, timeout: TimeInterval) throws -> CameraSSHHostProbe {
        do {
            let probe = try RawLabSSHTunnel.probeHostKey(
                host: host,
                port: port,
                requireWiFi: !CameraTCPChannel.isLoopbackFixture(host),
                timeout: timeout
            )
            return CameraSSHHostProbe(
                host: probe.host,
                port: probe.port,
                fingerprint: probe.fingerprint,
                keyType: probe.keyType
            )
        } catch let error as RawLabSSHError {
            throw CameraAccessAuthErrorMapper.map(error)
        }
    }

    func connect(
        host: String,
        port: UInt16,
        username: String,
        password: String,
        expectedFingerprint: String,
        timeout: TimeInterval
    ) throws -> CameraSSHTunneling {
        do {
            let tunnel = try RawLabSSHTunnel.connect(
                host: host,
                port: port,
                username: username,
                password: password,
                expectedFingerprint: expectedFingerprint,
                requireWiFi: !CameraTCPChannel.isLoopbackFixture(host),
                timeout: timeout
            )
            return NIOCameraSSHTunnelAdapter(tunnel: tunnel)
        } catch let error as RawLabSSHError {
            throw CameraAccessAuthErrorMapper.map(error)
        }
    }
}
#endif
