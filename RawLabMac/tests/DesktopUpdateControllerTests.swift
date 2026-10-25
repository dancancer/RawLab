import Foundation

@MainActor private final class FakeUpdateAdapter: UpdateAdapter {
    var unavailableReason: String?
    var canCheck = true
    var hasActiveSession: Bool { !canCheck || hasPreparedInstaller }
    var hasAvailableRelease = false
    var hasPreparedInstaller = false
    var token = UUID()
    var callback: ((UUID, UpdateAdapterEvent) -> Void)?
    var checks = 0, downloads = 0, cancellations = 0, installs = 0
    var rejectInstall = false
    func check(token: UUID, emit: @escaping (UUID, UpdateAdapterEvent) -> Void) throws {
        self.token = token; callback = emit; checks += 1; canCheck = false
    }
    func download(_ release: UpdateDescriptor, token: UUID) throws { self.token = token; hasAvailableRelease = false; downloads += 1 }
    func cancel() { cancellations += 1; hasPreparedInstaller = false; hasAvailableRelease = false; canCheck = true; callback?(token, .ended) }
    func install(restart: Bool) throws {
        installs += 1
        if rejectInstall { throw UpdateAdapterError(code: "install", detail: "Injected dispatch failure") }
        callback?(token, .pendingRestart)
    }
    func send(_ event: UpdateAdapterEvent) { if case .found(let release) = event { hasAvailableRelease = release != nil }; callback?(token, event) }
}

@main struct DesktopUpdateControllerTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }; print("PASS: \(message)")
    }
    @MainActor static func main() async throws {
        try stateRepair()
        try await installationFailureBlocksEditing()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-update-controller-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let unavailable = DesktopUpdateController(adapter: UnavailableUpdateAdapter("configuration"), gate: UpdateInstallGate(),
            store: UpdateStore(directory: root.appendingPathComponent("unavailable")), currentVersion: "0.8.2", currentBuild: "14")
        var allowed: Bool?
        unavailable.prepareForQuit { allowed = $0 }
        check(allowed == true, "An unsupported development build can quit without waiting for an updater")
        let adapter = FakeUpdateAdapter(), gate = UpdateInstallGate()
        let controller = DesktopUpdateController(adapter: adapter, gate: gate,
            store: UpdateStore(directory: root.appendingPathComponent("Updates")), currentVersion: "0.8.2", currentBuild: "14")
        let release = UpdateDescriptor(version: "0.9.1", build: "19", platform: "macos", architecture: "arm64", channel: "stable",
            assetURL: "https://example.invalid/update.zip", size: 12, sha256: nil, notes: "Release")
        controller.check(manual: true); adapter.send(.found(release))
        check(controller.state.phase == .available && adapter.downloads == 0, "Checking alone never downloads")
        controller.skip()
        check(controller.state.phase == .idle && controller.state.release == nil, "Skipping immediately removes the available update prompt")
        let later = DesktopUpdateController(adapter: adapter, gate: gate,
            store: UpdateStore(directory: root.appendingPathComponent("Updates")), currentVersion: "0.8.2", currentBuild: "14",
            now: { Date().addingTimeInterval(86401) })
        later.check(manual: false); adapter.send(.found(release))
        check(later.state.phase == .idle && adapter.downloads == 0, "Automatic checks respect skipped version even with automatic install off")
        later.check(manual: true); adapter.send(.found(release)); later.download()
        let stale = adapter.token
        adapter.send(.preparing); adapter.send(.failed("signature", "rejected")); adapter.send(.verified)
        check(later.state.phase == .failed && later.state.failure?.stage == .verifying, "Late verified callback cannot clear a persisted failure")
        check(later.canCheck, "A failed attempt releases its SDK session so explicit retry remains available")
        later.retry(); adapter.send(.found(release))
        adapter.callback?(stale, .verified)
        check(later.state.phase == .downloading && adapter.downloads == 2, "Explicit retry rechecks and redownloads with a new token")
        adapter.send(.preparing); adapter.hasPreparedInstaller = true; adapter.send(.verified)
        check(adapter.installs == 0 && later.canChooseInstall, "Ready update waits for this attempt's installation choice")
        allowed = nil; later.prepareForQuit { allowed = $0 }
        check(allowed == true && adapter.cancellations >= 2 && adapter.installs == 0, "Quit cancels an unchosen prepared installer instead of applying it")
        let recoveryRoot = root.appendingPathComponent("recovery"), recoveryStore = UpdateStore(directory: root.appendingPathComponent("recovery/Updates"))
        let edits = recoveryRoot.appendingPathComponent("Edits")
        try FileManager.default.createDirectory(at: edits, withIntermediateDirectories: true)
        let photo = edits.appendingPathComponent("photo.json"); try Data("old data".utf8).write(to: photo)
        let backups = UpdateDataBackup(dataRoot: recoveryRoot, updateRoot: recoveryStore.directory)
        let saved = try backups.create(previous: "0.8.2", target: "0.9.1", previousBuild: "14")
        var failed = UpdatePreferences(); var attempt = failed.pendingUpdate.beginCheck()
        _ = failed.pendingUpdate.found(release, token: attempt); attempt = failed.pendingUpdate.beginDownload()!
        _ = failed.pendingUpdate.preparing(token: attempt); _ = failed.pendingUpdate.verified(token: attempt)
        _ = failed.pendingUpdate.choose(.onQuit); _ = failed.pendingUpdate.admit(blockedBy: [])
        failed.pendingUpdate.backupPath = saved.path; failed.pendingUpdate.previousVersion = "0.8.2"; failed.pendingUpdate.previousBuild = "14"
        _ = failed.pendingUpdate.installing(token: attempt); _ = failed.pendingUpdate.awaitingRestart(token: attempt)
        try recoveryStore.save(failed)
        let healthy = DesktopUpdateController(adapter: FakeUpdateAdapter(), gate: UpdateInstallGate(), store: recoveryStore, currentVersion: "0.9.1", currentBuild: "19")
        healthy.finishStartupHealthCheck(healthy: true)
        check(healthy.state.phase == .complete && !healthy.canRestorePreviousData, "A healthy new version never offers automatic data downgrade")
        try recoveryStore.save(failed)
        let newer = DesktopUpdateController(adapter: FakeUpdateAdapter(), gate: UpdateInstallGate(), store: recoveryStore, currentVersion: "0.9.1", currentBuild: "19")
        newer.finishStartupHealthCheck(healthy: false)
        check(newer.requiresRecovery && !newer.canCheck && !newer.canRestorePreviousData, "Failed first boot blocks editing and cannot restore old data into the newer app")
        try malformedFailureStartup(store: recoveryStore, original: newer.preferences)
        let untrusted = DesktopUpdateController(adapter: UnavailableUpdateAdapter("identity"), gate: UpdateInstallGate(), store: recoveryStore, currentVersion: "0.8.2", currentBuild: "14")
        check(!untrusted.canRestorePreviousData, "Untrusted previous application cannot restore data")
        let wrongBuild = DesktopUpdateController(adapter: FakeUpdateAdapter(), gate: UpdateInstallGate(), store: recoveryStore, currentVersion: "0.8.2", currentBuild: "15")
        check(!wrongBuild.canRestorePreviousData, "Recovery binds the exact previous build")
        let recovery = DesktopUpdateController(adapter: FakeUpdateAdapter(), gate: UpdateInstallGate(), store: recoveryStore, currentVersion: "0.8.2", currentBuild: "14")
        try Data("new format".utf8).write(to: photo)
        check(recovery.canRestorePreviousData, "Matching trusted previous version offers explicit recovery before editing")
        await recovery.restorePreviousData()
        check(recovery.recoveryNeedsRestart && recovery.requiresRecovery && recovery.state.phase == .idle && recovery.preferences.skippedVersion == release.identity,
            "Restored data requires reopening and never reports the failed update as complete")
        try checkData(photo, "old data")
        let reopened = DesktopUpdateController(adapter: FakeUpdateAdapter(), gate: UpdateInstallGate(), store: recoveryStore, currentVersion: "0.8.2", currentBuild: "14")
        check(!reopened.requiresRecovery && !reopened.canRestorePreviousData, "Persisted recovery reopens without reusing the cached editor model")
    }
    static func checkData(_ path: URL, _ expected: String) throws {
        let value = try String(contentsOf: path, encoding: .utf8)
        check(value == expected, "Recovery restores the verified backup contents")
    }

    @MainActor static func installationFailureBlocksEditing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-install-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let edits = root.appendingPathComponent("Edits"); try FileManager.default.createDirectory(at: edits, withIntermediateDirectories: true)
        let photo = edits.appendingPathComponent("photo.json"), bytes = Data("committed edit".utf8); try bytes.write(to: photo)
        let store = UpdateStore(directory: root.appendingPathComponent("Updates")), adapter = FakeUpdateAdapter()
        let controller = DesktopUpdateController(adapter: adapter, gate: UpdateInstallGate(), store: store, currentVersion: "0.8.2", currentBuild: "14")
        let release = UpdateDescriptor(version: "0.9.1", build: "19", platform: "macos", architecture: "arm64", channel: "stable", assetURL: "https://example.invalid/update.zip", size: 12, sha256: nil, notes: "")
        check(!controller.blocksEditing, "Ordinary editing is available before installation")
        controller.check(manual: true); adapter.send(.found(release)); controller.download()
        adapter.send(.preparing); adapter.hasPreparedInstaller = true; adapter.send(.verified); adapter.rejectInstall = true
        controller.choose(.restartNow)
        for _ in 0..<400 where controller.state.phase != .failed || controller.preparingInstallation { try await Task.sleep(for: .milliseconds(10)) }
        check(controller.state.failure?.stage == .installing && controller.blocksEditing && !controller.canRestorePreviousData,
            "A dispatch failure keeps the active editor blocked before any recovery")
        let preserved = try Data(contentsOf: photo)
        check(preserved == bytes, "Failed dispatch preserves committed editor data")
        let reopened = DesktopUpdateController(adapter: FakeUpdateAdapter(), gate: UpdateInstallGate(), store: store, currentVersion: "0.8.2", currentBuild: "14")
        check(reopened.blocksEditing && reopened.canRestorePreviousData, "Reopening offers recovery while editing remains blocked")
        await reopened.restorePreviousData()
        check(reopened.blocksEditing && reopened.recoveryNeedsRestart, "Restored data remains blocked until the next launch")
    }

    @MainActor static func malformedFailureStartup(store: UpdateStore, original: UpdatePreferences) throws {
        defer { try? store.save(original) }
        let document = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        for name in ["missing", "null", "incomplete"] {
            var damaged = document, pending = document["pendingUpdate"] as! [String: Any]
            if name == "missing" { pending.removeValue(forKey: "failure") }
            else if name == "null" { pending["failure"] = NSNull() }
            else { pending["failure"] = ["stage": "pending_restart"] }
            damaged["pendingUpdate"] = pending
            let bytes = try JSONSerialization.data(withJSONObject: damaged); try bytes.write(to: store.stateURL)
            let reopened = DesktopUpdateController(adapter: FakeUpdateAdapter(), gate: UpdateInstallGate(), store: store,
                currentVersion: "0.9.1", currentBuild: "19")
            reopened.finishStartupHealthCheck(healthy: true)
            check(reopened.storageError != nil && !reopened.canCheck && !reopened.canChooseInstall && !reopened.canRepairState,
                "Malformed installation failure blocks startup and state reset: \(name)")
            let preserved = try Data(contentsOf: store.stateURL)
            check(preserved == bytes, "Blocked startup preserves the damaged failure record: \(name)")
        }
    }

    @MainActor static func stateRepair() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-controller-repair-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateStore(directory: root.appendingPathComponent("Updates"))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: store.stateURL)
        let adapter = FakeUpdateAdapter()
        let damaged = DesktopUpdateController(adapter: adapter, gate: UpdateInstallGate(), store: store, currentVersion: "0.8.2", currentBuild: "14")
        check(damaged.storageError != nil && damaged.canRepairState && !damaged.canCheck, "Corrupt pre-install state offers only explicit repair")
        damaged.repairState()
        damaged.setAutomaticCheck(true); damaged.setAutomaticInstall(true); damaged.cancel(); damaged.retry()
        damaged.finishStartupHealthCheck(healthy: true)
        check(damaged.storageError == nil && damaged.recoveryNeedsRestart && damaged.requiresRecovery && !damaged.canCheck && adapter.installs == 0,
            "Repair cannot reopen editing or install in the current process")
        check(!damaged.preferences.automaticCheck && !damaged.preferences.automaticInstall && damaged.preferences.stateRepairReceipt != nil,
            "Recovery actions cannot enable automatic updates or clear the startup receipt")
        let unhealthy = DesktopUpdateController(adapter: adapter, gate: UpdateInstallGate(), store: store, currentVersion: "0.8.2", currentBuild: "14")
        check(unhealthy.requiresStartupHealthCheck && !unhealthy.requiresRecovery, "Reopening repaired state requires data health validation")
        unhealthy.finishStartupHealthCheck(healthy: false)
        check(unhealthy.requiresRecovery && !unhealthy.canCheck && unhealthy.preferences.stateRepairReceipt != nil,
            "Unhealthy user data remains blocked after repair")
        let healthy = DesktopUpdateController(adapter: adapter, gate: UpdateInstallGate(), store: store, currentVersion: "0.8.2", currentBuild: "14")
        healthy.finishStartupHealthCheck(healthy: true)
        check(!healthy.requiresStartupHealthCheck && !healthy.requiresRecovery && healthy.canCheck && !healthy.preferences.automaticInstall,
            "Only a fresh healthy startup completes explicit state repair")
    }
}
