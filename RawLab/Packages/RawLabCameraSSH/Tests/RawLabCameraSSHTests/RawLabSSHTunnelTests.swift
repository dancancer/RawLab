import CryptoKit
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOPosix
import NIOSSH
import XCTest
@testable import RawLabCameraSSH

private final class TestUserAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods
    let expectedUser: String
    let expectedPassword: String
    var onAttempt: (() -> Void)?

    init(
        supportedMethods: NIOSSHAvailableUserAuthenticationMethods = .password,
        expectedUser: String = "sony",
        expectedPassword: String = "pass1234"
    ) {
        self.supportedAuthenticationMethods = supportedMethods
        self.expectedUser = expectedUser
        self.expectedPassword = expectedPassword
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        onAttempt?()
        guard supportedAuthenticationMethods.contains(.password),
              request.username == expectedUser,
              case .password(let pw) = request.request,
              pw.password == expectedPassword else {
            responsePromise.succeed(.failure)
            return
        }
        responsePromise.succeed(.success)
    }
}

private final class ChannelEchoHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let inbound = unwrapInboundIn(data)
        context.writeAndFlush(wrapOutboundOut(inbound), promise: nil)
    }
}

final class RawLabSSHTunnelTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var serverChannel: Channel?

    override func setUp() {
        super.setUp()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        try? serverChannel?.close().wait()
        serverChannel = nil
        try? group.syncShutdownGracefully()
        group = nil
        super.tearDown()
    }

    private func startTestServer(
        expectedUser: String = "sony",
        expectedPassword: String = "pass1234",
        supportedMethods: NIOSSHAvailableUserAuthenticationMethods = .password,
        allowLocalhostOnly: Bool = true,
        rejectDirectTCPIP: Bool = false,
        authCounter: UnsafeMutablePointer<Int>? = nil
    ) throws -> (port: UInt16, fingerprint: String) {
        let hostPrivateKey = NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey())
        let publicKeyString = String(openSSHPublicKey: hostPrivateKey.publicKey)
        guard let parsed = RawLabSSHFingerprint.parse(openSSHPublicKey: publicKeyString) else {
            XCTFail("Failed to parse test host public key")
            throw RawLabSSHError.disconnected
        }

        let authDelegate = TestUserAuthDelegate(
            supportedMethods: supportedMethods,
            expectedUser: expectedUser,
            expectedPassword: expectedPassword
        )
        authDelegate.onAttempt = {
            authCounter?.pointee += 1
        }

        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = NIOSSHHandler(
                        role: .server(
                            SSHServerConfiguration(
                                hostKeys: [hostPrivateKey],
                                userAuthDelegate: authDelegate
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { childChannel, channelType in
                            guard case .directTCPIP(let info) = channelType else {
                                return childChannel.eventLoop.makeFailedFuture(RawLabSSHError.channelOpenFailed("unsupported type"))
                            }
                            if rejectDirectTCPIP {
                                return childChannel.eventLoop.makeFailedFuture(
                                    RawLabSSHError.channelOpenFailed("administratively prohibited")
                                )
                            }
                            if allowLocalhostOnly && info.targetHost != "localhost" {
                                return childChannel.eventLoop.makeFailedFuture(
                                    RawLabSSHError.channelOpenFailed("Only localhost forwarding is allowed")
                                )
                            }
                            guard info.targetPort == 15740 || info.targetPort == 60152 else {
                                return childChannel.eventLoop.makeFailedFuture(
                                    RawLabSSHError.channelOpenFailed("Disallowed port \(info.targetPort)")
                                )
                            }
                            return childChannel.eventLoop.makeCompletedFuture {
                                try childChannel.pipeline.syncOperations.addHandler(ChannelEchoHandler())
                            }
                        }
                    )
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let bound = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        serverChannel = bound
        guard let port = bound.localAddress?.port else {
            throw RawLabSSHError.disconnected
        }
        return (UInt16(port), parsed.fingerprint)
    }

    func testFingerprintParsingAndNormalization() {
        let key = NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey()).publicKey
        let parsed = RawLabSSHFingerprint.parse(openSSHPublicKey: String(openSSHPublicKey: key))
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.keyType, "ecdsa-sha2-nistp256")
        XCTAssertTrue(parsed?.fingerprint.hasPrefix("SHA256:") == true)
        XCTAssertEqual(
            RawLabSSHFingerprint.normalizeSHA256(" \(parsed!.fingerprint)= "),
            parsed?.fingerprint
        )
        XCTAssertNil(RawLabSSHFingerprint.normalizeSHA256("MD5:aa:bb"))
        XCTAssertNil(RawLabSSHFingerprint.normalizeSHA256("SHA256:not-base64"))
        XCTAssertTrue(RawLabSSHFingerprint.constantTimeEquals("SHA256:abc", "SHA256:abc"))
        XCTAssertFalse(RawLabSSHFingerprint.constantTimeEquals("SHA256:abc", "SHA256:abd"))
    }

    func testProbeHostKeyDoesNotSendCredentials() throws {
        var authAttempts = 0
        let server = try startTestServer(authCounter: &authAttempts)
        let probe = try RawLabSSHTunnel.probeHostKey(
            host: "127.0.0.1",
            port: server.port,
            requireWiFi: false,
            timeout: 5
        )
        XCTAssertEqual(probe.keyType, "ecdsa-sha2-nistp256")
        XCTAssertEqual(probe.fingerprint, server.fingerprint)
        XCTAssertEqual(authAttempts, 0)
    }

    func testConnectRejectsMismatchedFingerprintBeforeSendingCredentials() throws {
        var authAttempts = 0
        let server = try startTestServer(authCounter: &authAttempts)
        let wrongFp = "SHA256:" + String(repeating: "A", count: 43)

        XCTAssertThrowsError(
            try RawLabSSHTunnel.connect(
                host: "127.0.0.1",
                port: server.port,
                username: "sony",
                password: "pass1234",
                expectedFingerprint: wrongFp,
                requireWiFi: false,
                timeout: 5
            )
        ) { error in
            guard case RawLabSSHError.fingerprintMismatch(_, let actual, _) = error else {
                XCTFail("Expected fingerprintMismatch, got \(error)")
                return
            }
            XCTAssertEqual(actual, server.fingerprint)
        }
        XCTAssertEqual(authAttempts, 0)
    }

    func testConnectRejectsWrongPasswordWithAuthenticationFailed() throws {
        let server = try startTestServer()
        XCTAssertThrowsError(
            try RawLabSSHTunnel.connect(
                host: "127.0.0.1",
                port: server.port,
                username: "sony",
                password: "wrong-password",
                expectedFingerprint: server.fingerprint,
                requireWiFi: false,
                timeout: 5
            )
        ) { error in
            XCTAssertEqual(error as? RawLabSSHError, .authenticationFailed("Camera SSH authentication failed"))
        }
    }

    func testConnectRejectsUnsupportedInteractiveOnlyAuth() throws {
        let server = try startTestServer(supportedMethods: .publicKey)
        XCTAssertThrowsError(
            try RawLabSSHTunnel.connect(
                host: "127.0.0.1",
                port: server.port,
                username: "sony",
                password: "pass1234",
                expectedFingerprint: server.fingerprint,
                requireWiFi: false,
                timeout: 5
            )
        ) { error in
            guard case RawLabSSHError.unsupportedAuthenticationMethod = error else {
                XCTFail("Expected unsupportedAuthenticationMethod, got \(error)")
                return
            }
        }
    }

    func testConnectForwardsOverLocalhostAndEnforcesAllowedPorts() throws {
        let server = try startTestServer(allowLocalhostOnly: true)
        let tunnel = try RawLabSSHTunnel.connect(
            host: "127.0.0.1",
            port: server.port,
            username: "sony",
            password: "pass1234",
            expectedFingerprint: server.fingerprint,
            requireWiFi: false,
            timeout: 5
        )
        defer { tunnel.close() }

        XCTAssertThrowsError(try tunnel.openDirectTCPIP(port: 80, allowedPorts: [15740])) { error in
            guard case RawLabSSHError.channelOpenFailed = error else {
                XCTFail("Expected channelOpenFailed, got \(error)")
                return
            }
        }

        let channel = try tunnel.openDirectTCPIP(port: 15740, allowedPorts: [15740], timeout: 5)
        let payload = Data("ptpip-over-ssh".utf8)
        try channel.write(payload)
        let echoed = try channel.read(payload.count)
        XCTAssertEqual(echoed, payload)

        channel.beginEventLoop()
        let liveViewChannel = try tunnel.openDirectTCPIP(port: 60152, allowedPorts: [60152], timeout: 5)
        let lvPayload = Data("GET /liveviewstream HTTP/1.1\r\n\r\n".utf8)
        try liveViewChannel.write(lvPayload)
        XCTAssertEqual(try liveViewChannel.read(lvPayload.count), lvPayload)
        liveViewChannel.close()
        channel.close()
    }

    func testServerRejectedDirectTCPIPThrowsChannelOpenFailed() throws {
        let server = try startTestServer(rejectDirectTCPIP: true)
        let tunnel = try RawLabSSHTunnel.connect(
            host: "127.0.0.1",
            port: server.port,
            username: "sony",
            password: "pass1234",
            expectedFingerprint: server.fingerprint,
            requireWiFi: false,
            timeout: 5
        )
        defer { tunnel.close() }

        XCTAssertThrowsError(try tunnel.openDirectTCPIP(port: 15740, allowedPorts: [15740], timeout: 5)) { error in
            guard case RawLabSSHError.channelOpenFailed = error else {
                XCTFail("Expected channelOpenFailed, got \(error)")
                return
            }
        }
    }
}
