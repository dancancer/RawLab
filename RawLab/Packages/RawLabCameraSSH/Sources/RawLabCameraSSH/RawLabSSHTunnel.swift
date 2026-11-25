import CryptoKit
import Foundation
import Network
import NIOCore
import NIOFoundationCompat
import NIOSSH
import NIOTransportServices

public struct RawLabSSHHostProbe: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let fingerprint: String
    public let keyType: String

    public init(host: String, port: UInt16, fingerprint: String, keyType: String) {
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
        self.keyType = keyType
    }
}

public enum RawLabSSHError: Error, Equatable, LocalizedError {
    case invalidEndpoint(String)
    case fingerprintMismatch(expected: String, actual: String, keyType: String)
    case authenticationFailed(String)
    case unsupportedAuthenticationMethod(String)
    case localNetworkDenied
    case connectionRefused
    case timeout
    case disconnected
    case channelOpenFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let message):
            return message
        case .fingerprintMismatch:
            return "Camera SSH host key fingerprint mismatch"
        case .authenticationFailed(let message):
            return message
        case .unsupportedAuthenticationMethod(let message):
            return message
        case .localNetworkDenied:
            return "Local network access is denied"
        case .connectionRefused:
            return "Camera SSH endpoint refused connection"
        case .timeout:
            return "Camera SSH operation timed out"
        case .disconnected:
            return "Camera SSH connection closed"
        case .channelOpenFailed(let message):
            return message
        case .cancelled:
            return "Camera SSH operation cancelled"
        }
    }
}

public enum RawLabSSHFingerprint {
    public static func parse(openSSHPublicKey: String) -> (keyType: String, fingerprint: String)? {
        let parts = openSSHPublicKey.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2,
              let keyBlob = Data(base64Encoded: String(parts[1])),
              !keyBlob.isEmpty else {
            return nil
        }
        let digest = SHA256.hash(data: keyBlob)
        let encoded = base64Unpadded(Data(digest))
        return (keyType: String(parts[0]), fingerprint: "SHA256:" + encoded)
    }

    public static func normalizeSHA256(_ value: String) -> String? {
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
        let canonical = base64Unpadded(decoded)
        guard canonical == unpadded else { return nil }
        return "SHA256:" + canonical
    }

    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }

    private static func base64Unpadded(_ data: Data) -> String {
        var encoded = data.base64EncodedString()
        while encoded.hasSuffix("=") {
            encoded.removeLast()
        }
        return encoded
    }
}

private enum EndpointValidation {
    static func isPermittedHost(_ host: String, allowLoopback: Bool) -> Bool {
        if allowLoopback && host == "127.0.0.1" {
            return true
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10 ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168) ||
            (octets[0] == 169 && octets[1] == 254)
    }
}

private final class DirectChannelBufferHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let condition = NSCondition()
    private var buffer = Data()
    private var eof = false
    private var terminalError: Error?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .channel = payload.type else { return }
        switch payload.data {
        case .byteBuffer(var byteBuffer):
            guard let bytes = byteBuffer.readBytes(length: byteBuffer.readableBytes), !bytes.isEmpty else {
                return
            }
            condition.lock()
            buffer.append(contentsOf: bytes)
            condition.broadcast()
            condition.unlock()
        case .fileRegion:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        markClosed(error: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        markClosed(error: error)
        context.close(promise: nil)
    }

    func markClosed(error: Error?) {
        condition.lock()
        eof = true
        if terminalError == nil {
            terminalError = error
        }
        condition.broadcast()
        condition.unlock()
    }

    func readExact(_ count: Int, timeout: TimeInterval) throws -> Data {
        guard count >= 0 else {
            throw RawLabSSHError.invalidEndpoint("Invalid read size")
        }
        if count == 0 {
            return Data()
        }
        let deadline = timeout > 0 ? Date().addingTimeInterval(timeout) : nil
        condition.lock()
        defer { condition.unlock() }
        while buffer.count < count {
            if let terminalError {
                throw RawLabSSHTunnel.mapError(terminalError, fallback: .disconnected)
            }
            if eof {
                throw RawLabSSHError.disconnected
            }
            if let deadline {
                if !condition.wait(until: deadline) {
                    if buffer.count >= count { break }
                    if let terminalError {
                        throw RawLabSSHTunnel.mapError(terminalError, fallback: .disconnected)
                    }
                    if eof {
                        throw RawLabSSHError.disconnected
                    }
                    throw RawLabSSHError.timeout
                }
            } else {
                condition.wait()
            }
        }
        let result = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return result
    }
}

public final class RawLabSSHDirectChannel {
    private let channel: Channel
    private let handler: DirectChannelBufferHandler
    private let lock = NSLock()
    private var readTimeout: TimeInterval
    private var closed = false
    private let onClose: () -> Void

    fileprivate init(
        channel: Channel,
        handler: DirectChannelBufferHandler,
        timeout: TimeInterval,
        onClose: @escaping () -> Void
    ) {
        self.channel = channel
        self.handler = handler
        self.readTimeout = timeout
        self.onClose = onClose
    }

    public func read(_ count: Int, maxBudget: Int = 8 << 20) throws -> Data {
        guard count >= 0, count <= maxBudget else {
            throw RawLabSSHError.invalidEndpoint("SSH channel read exceeds budget")
        }
        lock.lock()
        let isClosed = closed
        let timeout = readTimeout
        lock.unlock()
        guard !isClosed else {
            throw RawLabSSHError.cancelled
        }
        do {
            return try handler.readExact(count, timeout: timeout)
        } catch {
            close()
            throw error
        }
    }

    public func write(_ data: Data) throws {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard !isClosed else {
            throw RawLabSSHError.cancelled
        }
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.eventLoop.execute { [channel] in
            var buf = channel.allocator.buffer(capacity: data.count)
            buf.writeBytes(data)
            let msg = SSHChannelData(type: .channel, data: .byteBuffer(buf))
            channel.writeAndFlush(msg, promise: promise)
        }
        let semaphore = DispatchSemaphore(value: 0)
        var writeError: Error?
        promise.futureResult.whenComplete { result in
            if case .failure(let err) = result {
                writeError = err
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            close()
            throw RawLabSSHError.timeout
        }
        if let writeError {
            close()
            throw RawLabSSHTunnel.mapError(writeError, fallback: .disconnected)
        }
    }

    public func beginEventLoop() {
        lock.lock()
        readTimeout = 0
        lock.unlock()
    }

    public func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        handler.markClosed(error: nil)
        channel.close(promise: nil)
        onClose()
    }

    deinit {
        close()
    }
}

private struct ProbeCapturedError: Error {
    let probe: RawLabSSHHostProbe
}

private struct HostKeyMismatchCapturedError: Error {
    let expected: String
    let actual: String
    let keyType: String
}

private final class ProbeServerAuthDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let host: String
    private let port: UInt16

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let openSSHKey = String(openSSHPublicKey: hostKey)
        guard let parsed = RawLabSSHFingerprint.parse(openSSHPublicKey: openSSHKey) else {
            validationCompletePromise.fail(RawLabSSHError.disconnected)
            return
        }
        let probe = RawLabSSHHostProbe(
            host: host,
            port: port,
            fingerprint: parsed.fingerprint,
            keyType: parsed.keyType
        )
        // Always fail before userauth so probing never sends credentials.
        validationCompletePromise.fail(ProbeCapturedError(probe: probe))
    }
}

private final class ProbeNoCredentialsAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        nextChallengePromise.fail(RawLabSSHError.cancelled)
    }
}

private final class PinnedServerAuthDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let host: String
    private let port: UInt16
    private let expectedFingerprint: String
    private let lock = NSLock()
    private var matchedProbe: RawLabSSHHostProbe?

    init(host: String, port: UInt16, expectedFingerprint: String) {
        self.host = host
        self.port = port
        self.expectedFingerprint = expectedFingerprint
    }

    var verifiedProbe: RawLabSSHHostProbe? {
        lock.lock()
        defer { lock.unlock() }
        return matchedProbe
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let openSSHKey = String(openSSHPublicKey: hostKey)
        guard let parsed = RawLabSSHFingerprint.parse(openSSHPublicKey: openSSHKey) else {
            validationCompletePromise.fail(
                HostKeyMismatchCapturedError(expected: expectedFingerprint, actual: "", keyType: "unknown")
            )
            return
        }
        guard RawLabSSHFingerprint.constantTimeEquals(parsed.fingerprint, expectedFingerprint) else {
            validationCompletePromise.fail(
                HostKeyMismatchCapturedError(
                    expected: expectedFingerprint,
                    actual: parsed.fingerprint,
                    keyType: parsed.keyType
                )
            )
            return
        }
        lock.lock()
        matchedProbe = RawLabSSHHostProbe(
            host: host,
            port: port,
            fingerprint: parsed.fingerprint,
            keyType: parsed.keyType
        )
        lock.unlock()
        validationCompletePromise.succeed(())
    }
}

private final class SingleAttemptPasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String
    private var offeredPassword = false

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offeredPassword else {
            if !availableMethods.contains(.password) {
                nextChallengePromise.fail(
                    RawLabSSHError.unsupportedAuthenticationMethod(
                        "Camera SSH server requires an interactive authentication method unsupported on iOS"
                    )
                )
            } else {
                nextChallengePromise.fail(
                    RawLabSSHError.authenticationFailed("Camera SSH authentication failed")
                )
            }
            return
        }
        guard availableMethods.contains(.password) else {
            nextChallengePromise.fail(
                RawLabSSHError.unsupportedAuthenticationMethod(
                    "Camera SSH server requires an interactive authentication method unsupported on iOS"
                )
            )
            return
        }
        offeredPassword = true
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .password(.init(password: password))
            )
        )
    }
}

private final class ClientEventHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let authPromise: EventLoopPromise<Void>?
    private let onTerminalError: (Error) -> Void
    private var settled = false

    init(authPromise: EventLoopPromise<Void>?, onTerminalError: @escaping (Error) -> Void = { _ in }) {
        self.authPromise = authPromise
        self.onTerminalError = onTerminalError
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            if !settled {
                settled = true
                authPromise?.succeed(())
            }
            return
        }
        if let waiting = event as? NIOTSNetworkEvents.WaitingForConnectivity {
            let mapped = classifyConnectivityError(waiting.transientError, path: nil)
            if mapped == .localNetworkDenied || mapped == .connectionRefused {
                failIfPending(mapped)
                context.close(promise: nil)
                return
            }
            context.channel.getOption(NIOTSChannelOptions.currentPath).whenSuccess { [weak self] path in
                if path.unsatisfiedReason == .localNetworkDenied {
                    self?.failIfPending(RawLabSSHError.localNetworkDenied)
                    context.close(promise: nil)
                }
            }
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failIfPending(error)
        onTerminalError(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        failIfPending(RawLabSSHError.disconnected)
        onTerminalError(RawLabSSHError.disconnected)
        context.fireChannelInactive()
    }

    private func failIfPending(_ error: Error) {
        guard !settled else { return }
        settled = true
        authPromise?.fail(error)
    }
}

private func classifyConnectivityError(_ error: Error, path: NWPath?) -> RawLabSSHError {
    if let sshError = error as? RawLabSSHError {
        return sshError
    }
    if path?.unsatisfiedReason == .localNetworkDenied {
        return .localNetworkDenied
    }
    if let nwError = error as? NWError {
        if case .posix(let code) = nwError, code == .ECONNREFUSED {
            return .connectionRefused
        }
        if case .dns = nwError {
            return .disconnected
        }
    }
    let nsError = error as NSError
    if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(POSIXErrorCode.ECONNREFUSED.rawValue) {
        return .connectionRefused
    }
    return .disconnected
}

public final class RawLabSSHTunnel {
    public static let defaultSSHPort: UInt16 = 22
    public static let defaultForwardPort: UInt16 = 15740
    public static let forwardTargetHost = "localhost"
    public static let defaultTimeout: TimeInterval = 10

    public let hostProbe: RawLabSSHHostProbe

    private let group: NIOTSEventLoopGroup
    private let channel: Channel
    private let lock = NSLock()
    private var closed = false
    private var activeChannels: [ObjectIdentifier: () -> Void] = [:]

    private init(
        group: NIOTSEventLoopGroup,
        channel: Channel,
        hostProbe: RawLabSSHHostProbe
    ) {
        self.group = group
        self.channel = channel
        self.hostProbe = hostProbe
    }

    public static func probeHostKey(
        host: String,
        port: UInt16 = defaultSSHPort,
        requireWiFi: Bool = true,
        timeout: TimeInterval = defaultTimeout
    ) throws -> RawLabSSHHostProbe {
        guard EndpointValidation.isPermittedHost(host, allowLoopback: !requireWiFi), port > 0 else {
            throw RawLabSSHError.invalidEndpoint("Camera SSH endpoint must be a local IPv4 address")
        }
        let group = NIOTSEventLoopGroup(loopCount: 1)
        var channel: Channel?
        defer {
            try? channel?.close().wait()
            try? group.syncShutdownGracefully()
        }

        let probePromise = group.next().makePromise(of: Void.self)
        let serverDelegate = ProbeServerAuthDelegate(host: host, port: port)
        let userDelegate = ProbeNoCredentialsAuthDelegate()
        let bootstrap = makeClientBootstrap(
            group: group,
            requireWiFi: requireWiFi,
            timeout: timeout,
            userAuthDelegate: userDelegate,
            serverAuthDelegate: serverDelegate,
            authPromise: probePromise
        )

        do {
            channel = try bootstrap.connect(host: host, port: Int(port)).wait()
            try waitFuture(probePromise.futureResult, timeout: timeout) {
                channel?.close(promise: nil)
            }
            throw RawLabSSHError.disconnected
        } catch let captured as ProbeCapturedError {
            return captured.probe
        } catch {
            throw mapError(error, fallback: .disconnected)
        }
    }

    public static func connect(
        host: String,
        port: UInt16 = defaultSSHPort,
        username: String,
        password: String,
        expectedFingerprint: String,
        requireWiFi: Bool = true,
        timeout: TimeInterval = defaultTimeout
    ) throws -> RawLabSSHTunnel {
        guard EndpointValidation.isPermittedHost(host, allowLoopback: !requireWiFi), port > 0 else {
            throw RawLabSSHError.invalidEndpoint("Camera SSH endpoint must be a local IPv4 address")
        }
        guard let normalizedFingerprint = RawLabSSHFingerprint.normalizeSHA256(expectedFingerprint) else {
            throw RawLabSSHError.fingerprintMismatch(
                expected: expectedFingerprint,
                actual: "",
                keyType: "unknown"
            )
        }
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty, !password.isEmpty else {
            throw RawLabSSHError.authenticationFailed("Camera SSH username and password are required")
        }

        let group = NIOTSEventLoopGroup(loopCount: 1)
        var connectedChannel: Channel?
        let authPromise = group.next().makePromise(of: Void.self)
        let serverDelegate = PinnedServerAuthDelegate(
            host: host,
            port: port,
            expectedFingerprint: normalizedFingerprint
        )
        let userDelegate = SingleAttemptPasswordAuthDelegate(username: trimmedUser, password: password)
        let bootstrap = makeClientBootstrap(
            group: group,
            requireWiFi: requireWiFi,
            timeout: timeout,
            userAuthDelegate: userDelegate,
            serverAuthDelegate: serverDelegate,
            authPromise: authPromise
        )

        do {
            let channel = try bootstrap.connect(host: host, port: Int(port)).wait()
            connectedChannel = channel
            try waitFuture(authPromise.futureResult, timeout: timeout) {
                channel.close(promise: nil)
            }
            guard let verifiedProbe = serverDelegate.verifiedProbe else {
                throw RawLabSSHError.fingerprintMismatch(
                    expected: normalizedFingerprint,
                    actual: "",
                    keyType: "unknown"
                )
            }
            return RawLabSSHTunnel(group: group, channel: channel, hostProbe: verifiedProbe)
        } catch {
            try? connectedChannel?.close().wait()
            try? group.syncShutdownGracefully()
            throw mapError(error, fallback: .disconnected)
        }
    }

    public func openDirectTCPIP(
        port: UInt16 = defaultForwardPort,
        allowedPorts: Set<UInt16> = [defaultForwardPort],
        timeout: TimeInterval = defaultTimeout
    ) throws -> RawLabSSHDirectChannel {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard !isClosed, channel.isActive else {
            throw RawLabSSHError.disconnected
        }
        guard allowedPorts.contains(port) else {
            throw RawLabSSHError.channelOpenFailed("Port \(port) is not permitted over camera SSH tunnel")
        }

        let handler = DirectChannelBufferHandler()
        let childPromise = channel.eventLoop.makePromise(of: Channel.self)
        let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        let directTCPIP = SSHChannelType.DirectTCPIP(
            targetHost: Self.forwardTargetHost,
            targetPort: Int(port),
            originatorAddress: originator
        )

        channel.eventLoop.execute { [channel] in
            channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
                switch result {
                case .failure(let error):
                    childPromise.fail(error)
                case .success(let sshHandler):
                    sshHandler.createChannel(childPromise, channelType: .directTCPIP(directTCPIP)) { childChannel, channelType in
                        guard case .directTCPIP = channelType else {
                            return childChannel.eventLoop.makeFailedFuture(
                                RawLabSSHError.channelOpenFailed("Unexpected SSH channel type")
                            )
                        }
                        return childChannel.pipeline.addHandler(handler)
                    }
                }
            }
        }

        do {
            let childChannel = try Self.waitFuture(childPromise.futureResult, timeout: timeout) {
                childPromise.fail(RawLabSSHError.timeout)
            }
            var identifier: ObjectIdentifier?
            let direct = RawLabSSHDirectChannel(
                channel: childChannel,
                handler: handler,
                timeout: timeout,
                onClose: { [weak self] in
                    guard let self, let id = identifier else { return }
                    self.lock.lock()
                    self.activeChannels.removeValue(forKey: id)
                    self.lock.unlock()
                }
            )
            let id = ObjectIdentifier(direct)
            identifier = id
            lock.lock()
            let closedDuringOpen = closed
            if !closedDuringOpen {
                activeChannels[id] = { [weak direct] in direct?.close() }
            }
            lock.unlock()
            if closedDuringOpen {
                direct.close()
                throw RawLabSSHError.cancelled
            }
            return direct
        } catch let sshError as RawLabSSHError {
            throw sshError
        } catch {
            throw RawLabSSHError.channelOpenFailed("Failed to open forwarded channel to port \(port): \(error)")
        }
    }

    public func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let closeHandlers = Array(activeChannels.values)
        activeChannels.removeAll()
        lock.unlock()

        for closeChild in closeHandlers {
            closeChild()
        }
        if channel.eventLoop.inEventLoop {
            channel.close(promise: nil)
            group.shutdownGracefully { _ in }
        } else {
            try? channel.close().wait()
            try? group.syncShutdownGracefully()
        }
    }

    deinit {
        close()
    }

    private static func makeClientBootstrap(
        group: NIOTSEventLoopGroup,
        requireWiFi: Bool,
        timeout: TimeInterval,
        userAuthDelegate: NIOSSHClientUserAuthenticationDelegate,
        serverAuthDelegate: NIOSSHClientServerAuthenticationDelegate,
        authPromise: EventLoopPromise<Void>
    ) -> NIOTSConnectionBootstrap {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let nanos = Int64(max(1.0, timeout) * 1_000_000_000)

        return NIOTSConnectionBootstrap(group: group)
            .connectTimeout(.nanoseconds(nanos))
            .tcpOptions(tcpOptions)
            .configureNWParameters { parameters in
                if requireWiFi {
                    parameters.requiredInterfaceType = .wifi
                }
            }
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    let ssh = NIOSSHHandler(
                        role: .client(
                            SSHClientConfiguration(
                                userAuthDelegate: userAuthDelegate,
                                serverAuthDelegate: serverAuthDelegate
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try sync.addHandler(ssh)
                    try sync.addHandler(ClientEventHandler(authPromise: authPromise))
                }
            }
    }

    private static func waitFuture<T>(
        _ future: EventLoopFuture<T>,
        timeout: TimeInterval,
        onTimeout: @escaping () -> Void
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<T, Error>?
        future.whenComplete { result in
            outcome = result
            semaphore.signal()
        }
        let waitResult = semaphore.wait(timeout: .now() + max(0.5, timeout))
        if waitResult == .timedOut {
            onTimeout()
            _ = semaphore.wait(timeout: .now() + 0.5)
            if case .failure(let error) = outcome {
                throw error
            }
            throw RawLabSSHError.timeout
        }
        switch outcome {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case nil:
            throw RawLabSSHError.disconnected
        }
    }

    fileprivate static func mapError(_ error: Error, fallback: RawLabSSHError) -> RawLabSSHError {
        if let sshError = error as? RawLabSSHError {
            return sshError
        }
        if let mismatch = error as? HostKeyMismatchCapturedError {
            return .fingerprintMismatch(expected: mismatch.expected, actual: mismatch.actual, keyType: mismatch.keyType)
        }
        if let channelError = error as? ChannelError {
            switch channelError {
            case .connectTimeout:
                return .timeout
            default:
                break
            }
        }
        if error is NIOSSHError {
            let text = String(describing: error).lowercased()
            if text.contains("timeout") { return .timeout }
            if text.contains("authentication") || text.contains("userauth") {
                return .authenticationFailed("Camera SSH authentication failed")
            }
            return fallback
        }
        let connectivity = classifyConnectivityError(error, path: nil)
        if connectivity != .disconnected {
            return connectivity
        }
        return fallback
    }
}
