#if canImport(Sparkle)
import Foundation
import Sparkle

@MainActor final class SparkleUpdateAdapter: NSObject, UpdateAdapter, SPUUserDriver, SPUUpdaterDelegate {
    let trust: MacUpdateTrust
    var unavailableReason: String? { nil }
    var canCheck: Bool { !validatingHost && (updater == nil || updater?.canCheckForUpdates == true) }
    var hasActiveSession: Bool { validatingHost || updater?.sessionInProgress == true || foundReply != nil || hasPreparedInstaller }
    var hasAvailableRelease: Bool { foundReply != nil && !cancelled }
    var hasPreparedInstaller: Bool { readyReply != nil || extracting }
    private var updater: SPUUpdater?
    private var token = UUID()
    private var emit: ((UUID, UpdateAdapterEvent) -> Void)?
    private var foundReply: ((SPUUserUpdateChoice) -> Void)?
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    private var cancellation: (() -> Void)?
    private var descriptor: UpdateDescriptor?
    private var packageSignature: String?
    private var packageValidation: Task<Void, Never>?
    private var packageVerified = false
    private var cancelled = false
    private var extracting = false
    private var installAuthorized = false
    private var validatingHost = false
    private var expected: UInt64 = 0
    private var received: UInt64 = 0

    init(trust: MacUpdateTrust) { self.trust = trust }

    func validateHostTrust() async throws {
        let trust = self.trust
        try await Task.detached { try trust.validateHost() }.value
    }

    func check(token: UUID, emit: @escaping (UUID, UpdateAdapterEvent) -> Void) throws {
        guard canCheck else { throw UpdateAdapterError(code: "busy", detail: "") }
        self.token = token; self.emit = emit; cancelled = false; extracting = false; installAuthorized = false
        descriptor = nil; packageSignature = nil; packageVerified = false; expected = 0; received = 0
        validatingHost = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let trust = self.trust
                try await Task.detached { try trust.validateHost() }.value
                guard self.token == token, !self.cancelled, self.validatingHost else { return }
                self.validatingHost = false
                try self.beginSDKCheck()
            } catch {
                guard self.token == token, !self.cancelled else { return }
                self.validatingHost = false
                self.send(.failed("identity", error.localizedDescription)); self.emit?(token, .ended)
            }
        }
    }

    private func beginSDKCheck() throws {
        if updater == nil {
            let value = SPUUpdater(hostBundle: trust.bundle, applicationBundle: trust.bundle, userDriver: self, delegate: self)
            value.automaticallyChecksForUpdates = false
            value.automaticallyDownloadsUpdates = false
            value.sendsSystemProfile = false
            try value.start(); _ = value.clearFeedURLFromUserDefaults(); updater = value
        }
        updater?.checkForUpdates()
    }

    func download(_ release: UpdateDescriptor, token: UUID) throws {
        guard descriptor?.identity == release.identity, let reply = foundReply, !cancelled else {
            throw UpdateAdapterError(code: "recheck", detail: "")
        }
        guard let signature = packageSignature, let url = URL(string: release.assetURL) else {
            throw UpdateAdapterError(code: "identity", detail: "Missing update package identity")
        }
        self.token = token; packageVerified = false
        let trust = self.trust
        // 在 Sparkle 启动安装器之前验证，避免进程意外退出时绕过代码证书门禁。
        // 两次下载以同一个已签名 appcast 的 EdDSA 签名绑定，不能仅凭相同 URL 信任包内容。
        packageValidation = Task { [weak self] in
            do {
                let (archive, response) = try await URLSession.shared.download(from: url)
                defer { try? FileManager.default.removeItem(at: archive) }
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                    throw UpdateAdapterError(code: "download", detail: "Cannot download package for identity verification")
                }
                try Task.checkCancellation()
                self?.send(.preparing)
                try await Task.detached { try trust.validatePackage(at: archive, release: release, signature: signature) }.value
                guard let self, self.token == token, !self.cancelled, !Task.isCancelled else { return }
                self.packageValidation = nil; self.packageVerified = true; self.foundReply = nil
                reply(.install)
            } catch {
                guard let self, self.token == token, !self.cancelled, !Task.isCancelled else { return }
                self.packageValidation = nil
                self.send(.failed((error as? UpdateAdapterError)?.code ?? "package", error.localizedDescription))
                self.cancel()
            }
        }
    }

    func cancel() {
        cancelled = true; installAuthorized = false
        packageValidation?.cancel(); packageValidation = nil; packageVerified = false
        if validatingHost { validatingHost = false; emit?(token, .ended) }
        if let ready = readyReply { readyReply = nil; ready(.skip) }
        else if let found = foundReply { foundReply = nil; found(.skip) }
        else if let cancel = cancellation { cancellation = nil; cancel() }
        // 提取期间 SDK 不提供取消入口；准备回调到达后立即回复 skip。
    }

    func install(restart: Bool) async throws {
        let trust = self.trust
        try await Task.detached { try trust.validateHost() }.value
        guard let reply = readyReply, packageVerified, !cancelled else { throw UpdateAdapterError(code: "recheck", detail: "") }
        installAuthorized = true; readyReply = nil
        reply(restart ? .install : .dismiss)
    }

    private func send(_ event: UpdateAdapterEvent) { if !cancelled { emit?(token, event) } }
    func feedURLString(for updater: SPUUpdater) -> String? { trust.feed.absoluteString }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { [] }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate item: SUAppcastItem) -> Bool { false }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard !item.isDeltaUpdate else { throw UpdateAdapterError(code: "metadata", detail: "Full update archive required") }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, automaticUpdateDownloading: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation; if cancelled { cancel() }
    }
    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancellation = nil
        guard !cancelled else { reply(.skip); return }
        // 恢复的 installer 不能继承上一进程的安装许可。
        guard state.stage == .notDownloaded else { reply(.skip); send(.failed("interrupted", "")); return }
        guard item.signingValidationStatus == .succeeded, !item.isInformationOnlyUpdate, !item.isDeltaUpdate,
              let url = item.fileURL, url.scheme == "https", url.host == trust.feed.host,
              url.pathExtension.lowercased() == "zip",
              (url.port ?? 443) == (trust.feed.port ?? 443), url.user == nil, url.password == nil,
              item.contentLength > 0,
              let enclosure = item.propertiesDictionary["enclosure"] as? [String: Any],
              let signature = enclosure["sparkle:edSignature"] as? String,
              Data(base64Encoded: signature)?.count == 64,
              enclosure["rawlab:architecture"] as? String == trust.architecture,
              let hash = enclosure["rawlab:sha256"] as? String,
              hash.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil else {
            reply(.skip); send(.failed("metadata", "")); return
        }
        let result = UpdateDescriptor(version: item.displayVersionString, build: item.versionString, platform: "macos",
            architecture: trust.architecture, channel: "stable", assetURL: url.absoluteString, size: item.contentLength,
            sha256: hash.lowercased(), notes: item.itemDescription ?? "")
        descriptor = result; packageSignature = signature; foundReply = reply; send(.found(result))
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { send(.found(nil)); acknowledgement() }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        send(.failed("framework", error.localizedDescription)); acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation; if cancelled { cancel() }
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { expected = expectedContentLength }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received = received.addingReportingOverflow(length).overflow ? UInt64.max : received + length
        if expected > 0 { send(.progress(min(1, Double(received) / Double(expected)))) }
    }
    func showDownloadDidStartExtractingUpdate() { cancellation = nil; extracting = true; send(.preparing) }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        extracting = false
        guard !cancelled else { reply(.skip); return }
        guard packageVerified else {
            reply(.skip); send(.failed("identity", "Missing update package identity")); return
        }
        readyReply = reply; send(.verified)
    }
    func showInstallingUpdate(withApplicationTerminated terminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        if installAuthorized { send(.pendingRestart) }
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        // 当前进程无法证明新版已健康启动。
        send(.pendingRestart); acknowledgement()
    }
    func dismissUpdateInstallation() {
        packageValidation?.cancel(); packageValidation = nil; packageVerified = false
        foundReply = nil; readyReply = nil; cancellation = nil; extracting = false
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        !installAuthorized
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        let endedToken = token
        DispatchQueue.main.async { [weak self] in self?.emit?(endedToken, .ended) }
    }
}
#endif
