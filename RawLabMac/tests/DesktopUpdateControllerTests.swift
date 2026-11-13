import Foundation
import AppKit
import SwiftUI

@_cdecl("sony2fuji_validate_look") func stubValidateLook(_: UnsafePointer<CChar>?, _: UnsafeMutablePointer<sony2fuji_look_format>?, _: UnsafeMutablePointer<UInt32>?) -> sony2fuji_status { SONY2FUJI_STATUS_INVALID_ARGUMENT }
@_cdecl("sony2fuji_inspect_lut_color") func stubInspectLUTColor(_: UnsafePointer<CChar>?) -> sony2fuji_lut_color_state { sony2fuji_lut_color_state(rawValue: 0) }
@_cdecl("sony2fuji_inspect_lut_compatibility") func stubInspectLUTCompatibility(_: UnsafePointer<CChar>?, _: UnsafeMutablePointer<sony2fuji_blob>?) -> sony2fuji_status { SONY2FUJI_STATUS_INVALID_ARGUMENT }
@_cdecl("sony2fuji_prepare_lut_compatibility") func stubPrepareLUTCompatibility(_: UnsafePointer<CChar>?, _: UnsafePointer<CChar>?, _: UnsafeMutablePointer<sony2fuji_blob>?) -> sony2fuji_status { SONY2FUJI_STATUS_INVALID_ARGUMENT }
@_cdecl("sony2fuji_compile_dcp_with_options") func stubCompileDCP(_: UnsafeRawPointer?, _: Int, _: UnsafePointer<CChar>?, _: UnsafeRawPointer?, _: Int, _: UInt32, _: UnsafeMutablePointer<sony2fuji_blob>?, _: UnsafeMutablePointer<sony2fuji_dcp_error>?) -> sony2fuji_status { SONY2FUJI_STATUS_INVALID_ARGUMENT }
@_cdecl("sony2fuji_release_blob") func stubReleaseBlob(_: UnsafeMutablePointer<sony2fuji_blob>?) {}

enum ParameterValueField { static var hasPendingInputs = false }

@MainActor final class EditorModel {
    struct Scheduler { var interacting = false }
    struct AIState { var isRunning = false }
    final class BatchStub {
        var running = false, stopping = false, validating = false, previewing = false, updateJournalFailed = false
        func prepareForUpdate() -> Bool { !updateJournalFailed }
    }
    var editStore: AnyObject? = NSObject()
    var lookLibrary: LookLibrary?
    var updateJournalLoadFailed = false
    let presetStore: AdjustmentPresetStore
    var batch: BatchStub?
    var geometryDraft: Any?
    var scheduler = Scheduler()
    var dirty = false
    var saveError: String?
    var workerActive = false, busy = false, exporting = false, lookLibraryBusy = false
    var aiState = AIState()
    init(presetDirectory: URL, lookDirectory: URL) {
        presetStore = AdjustmentPresetStore(directory: presetDirectory)
        lookLibrary = try? LookLibrary(directory: lookDirectory)
    }
    func saveEdits() -> Bool { saveError == nil && editStore != nil }
}

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
    var trustError: UpdateAdapterError?
    var onPrepareInstall: (() -> Void)?
    func validateHostTrust() async throws { if let trustError { throw trustError } }
    func prepareInstall() async throws {
        onPrepareInstall?()
        try await validateHostTrust()
        guard hasPreparedInstaller else { throw UpdateAdapterError(code: "recheck", detail: "") }
    }
    func check(token: UUID, emit: @escaping (UUID, UpdateAdapterEvent) -> Void) throws {
        self.token = token; callback = emit; checks += 1; canCheck = false
    }
    func download(_ release: UpdateDescriptor, token: UUID) throws { self.token = token; hasAvailableRelease = false; downloads += 1 }
    func cancel() { cancellations += 1; hasPreparedInstaller = false; hasAvailableRelease = false; canCheck = true; callback?(token, .ended) }
    func install(restart: Bool) throws {
        guard hasPreparedInstaller else { throw UpdateAdapterError(code: "recheck", detail: "") }
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
        try await automaticCheckRetries()
        try await stateRepair()
        try await storageFailureCriticalityAndRetry()
        try await preHandoffFailureAllowsRetry()
        try await presetAndLookGateAndHealthCodes()
        try await installationFailureBlocksEditing()
        try await blockedQuitFallsBack()
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
        var saved = try backups.create(previous: "0.8.2", target: "0.9.1", previousBuild: "14")
        var failed = UpdatePreferences(); var attempt = failed.pendingUpdate.beginCheck()
        _ = failed.pendingUpdate.found(release, token: attempt); attempt = failed.pendingUpdate.beginDownload()!
        _ = failed.pendingUpdate.preparing(token: attempt); _ = failed.pendingUpdate.verified(token: attempt)
        _ = failed.pendingUpdate.choose(.onQuit); _ = failed.pendingUpdate.admit(blockedBy: [])
        failed.pendingUpdate.backupPath = saved.path; failed.pendingUpdate.previousVersion = "0.8.2"; failed.pendingUpdate.previousBuild = "14"
        _ = failed.pendingUpdate.installing(token: attempt); _ = failed.pendingUpdate.awaitingRestart(token: attempt)
        try recoveryStore.save(failed)
        let healthAdapter = FakeUpdateAdapter()
        healthAdapter.trustError = UpdateAdapterError(code: "trust_temporary", detail: "Injected timeout")
        let healthy = DesktopUpdateController(adapter: healthAdapter, gate: UpdateInstallGate(), store: recoveryStore, currentVersion: "0.9.1", currentBuild: "19")
        await healthy.finishStartupHealthCheck(healthy: true)
        check(healthy.requiresStartupHealthCheck && healthy.state.phase == .pendingRestart && !healthy.requiresRecovery,
            "Temporary host assessment leaves the persisted installation pending for retry")
        healthAdapter.trustError = nil
        await healthy.finishStartupHealthCheck(healthy: true)
        check(healthy.state.phase == .complete && !healthy.canRestorePreviousData, "A healthy new version never offers automatic data downgrade")
        check(healthy.state.backupPath == nil && !FileManager.default.fileExists(atPath: saved.path),
            "Successful health check clears the persisted backup reference and removes the completed backup")
        saved = try backups.create(previous: "0.8.2", target: "0.9.1", previousBuild: "14")
        failed.pendingUpdate.backupPath = saved.path
        try recoveryStore.save(failed)
        let newer = DesktopUpdateController(adapter: FakeUpdateAdapter(), gate: UpdateInstallGate(), store: recoveryStore, currentVersion: "0.9.1", currentBuild: "19")
        await newer.finishStartupHealthCheck(healthy: false)
        check(newer.requiresRecovery && !newer.canCheck && !newer.canRestorePreviousData, "Failed first boot blocks editing and cannot restore old data into the newer app")
        let failedBeforeQuit = newer.state
        allowed = nil; newer.prepareForQuit { allowed = $0 }
        check(allowed == true && newer.state == failedBeforeQuit,
            "Normal quit preserves the failed startup state and permits closing the app")
        let persistedFailure = try recoveryStore.load(automaticCheck: true).pendingUpdate
        check(persistedFailure == failedBeforeQuit && FileManager.default.fileExists(atPath: saved.path),
            "Normal quit keeps the durable recovery pointers and backup for the trusted previous version")
        _ = try backups.verify(saved)
        try await malformedFailureStartup(store: recoveryStore, original: newer.preferences)
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
        let orphan = try backups.create(previous: "0.8.2", target: "0.9.1", previousBuild: "14")
        let reopened = DesktopUpdateController(adapter: FakeUpdateAdapter(), gate: UpdateInstallGate(), store: recoveryStore, currentVersion: "0.8.2", currentBuild: "14")
        check(!reopened.requiresRecovery && !reopened.canRestorePreviousData, "Persisted recovery reopens without reusing the cached editor model")
        check(!FileManager.default.fileExists(atPath: orphan.path), "Fresh startup retries cleanup of verified unreferenced backups")
    }
    @MainActor static func automaticCheckRetries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-check-retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateStore(directory: root), adapter = FakeUpdateAdapter()
        var time = Date(timeIntervalSince1970: 1800000000)
        let controller = DesktopUpdateController(adapter: adapter, gate: UpdateInstallGate(), store: store,
            currentVersion: "0.8.2", currentBuild: "14", now: { time })
        controller.check(manual: false); adapter.send(.failed("network", "offline"))
        check(controller.state.failure?.stage == .checking, "Check failure persists its checking stage")
        controller.check(manual: false)
        check(adapter.checks == 1, "Failed automatic check respects the daily retry interval")
        time.addTimeInterval(86401)
        let reopened = DesktopUpdateController(adapter: adapter, gate: UpdateInstallGate(), store: store,
            currentVersion: "0.8.2", currentBuild: "14", now: { time })
        reopened.check(manual: false)
        check(adapter.checks == 2 && reopened.state.phase == .checking, "Failed check retries automatically the next day after reopening")
        // Simulate the process exiting before a check callback arrives.
        time.addTimeInterval(86401)
        let afterInterruption = FakeUpdateAdapter()
        let interrupted = DesktopUpdateController(adapter: afterInterruption, gate: UpdateInstallGate(), store: store,
            currentVersion: "0.8.2", currentBuild: "14", now: { time })
        interrupted.check(manual: false)
        check(afterInterruption.checks == 1, "Interrupted check also retries automatically the next day")
        let release = UpdateDescriptor(version: "0.9.1", build: "19", platform: "macos", architecture: "arm64", channel: "stable",
            assetURL: "https://example.invalid/update.zip", size: 12, sha256: nil, notes: "")
        afterInterruption.send(.found(release)); interrupted.download(); afterInterruption.send(.failed("download", "offline"))
        time.addTimeInterval(86401); interrupted.check(manual: false)
        check(afterInterruption.checks == 1 && interrupted.state.failure?.stage == .downloading,
            "Download failure still waits for an explicit retry after a day")
    }

    @MainActor static func blockedQuitFallsBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-blocked-quit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = FakeUpdateAdapter(), gate = UpdateInstallGate(), owner = NSObject()
        gate.register(owner, status: { UpdateSessionStatus(draft: true) }, save: { true })
        let controller = DesktopUpdateController(adapter: adapter, gate: gate,
            store: UpdateStore(directory: root.appendingPathComponent("Updates")), currentVersion: "0.8.2", currentBuild: "14")
        let release = UpdateDescriptor(version: "0.9.1", build: "19", platform: "macos", architecture: "arm64", channel: "stable",
            assetURL: "https://example.invalid/update.zip", size: 12, sha256: nil, notes: "")
        controller.check(manual: true); adapter.send(.found(release)); controller.download()
        adapter.send(.preparing); adapter.hasPreparedInstaller = true; adapter.send(.verified)
        controller.choose(.onQuit)
        let allowed = await withCheckedContinuation { continuation in
            controller.prepareForQuit { continuation.resume(returning: $0) }
        }
        check(allowed && adapter.installs == 0 && !adapter.hasActiveSession,
            "Blocked install-on-quit cancels the installer and resumes ordinary draft confirmation")
        check(controller.state.choice == .onQuit, "Skipped installation keeps the user's install-on-quit choice")
        let noSession = await withCheckedContinuation { continuation in
            controller.prepareForQuit { continuation.resume(returning: $0) }
        }
        check(noSession && controller.state.phase == .available && controller.state.choice == .onQuit,
            "Ordinary quit without an SDK session preserves the install choice in a resumable state")
        let preserved = try Data(contentsOf: UpdateStore(directory: root.appendingPathComponent("Updates")).stateURL)
        let changedStore = UpdateStore(directory: root.appendingPathComponent("Changed"))
        try FileManager.default.createDirectory(at: changedStore.directory, withIntermediateDirectories: true)
        try preserved.write(to: changedStore.stateURL)
        let changedAdapter = FakeUpdateAdapter()
        let changed = DesktopUpdateController(adapter: changedAdapter, gate: UpdateInstallGate(), store: changedStore,
            currentVersion: "0.8.2", currentBuild: "14")
        changed.refreshGate()
        let newer = UpdateDescriptor(version: "0.9.2", build: "20", platform: "macos", architecture: "arm64", channel: "stable",
            assetURL: "https://example.invalid/new-update.zip", size: 13, sha256: nil, notes: "")
        changedAdapter.send(.found(newer))
        check(changed.state.phase == .available && changed.state.choice == .none && changedAdapter.downloads == 0,
            "A changed release does not inherit a previous quit choice or its download retry")
        let nextAdapter = FakeUpdateAdapter()
        let reopened = DesktopUpdateController(adapter: nextAdapter, gate: UpdateInstallGate(),
            store: UpdateStore(directory: root.appendingPathComponent("Updates")), currentVersion: "0.8.2", currentBuild: "14")
        reopened.refreshGate()
        check(nextAdapter.checks == 1, "A preserved quit choice revalidates the selected release on reopening")
        nextAdapter.send(.found(release))
        check(nextAdapter.downloads == 1, "The previously selected release is prepared again without another manual choice")
        nextAdapter.send(.preparing); nextAdapter.hasPreparedInstaller = true; nextAdapter.send(.verified)
        let completed = await withCheckedContinuation { continuation in
            reopened.prepareForQuit { continuation.resume(returning: $0) }
        }
        check(completed && nextAdapter.installs == 1, "The next ordinary quit uses the preserved installation choice")
    }

    static func checkData(_ path: URL, _ expected: String) throws {
        let value = try String(contentsOf: path, encoding: .utf8)
        check(value == expected, "Recovery restores the verified backup contents")
    }

    @MainActor static func renderPNG(_ view: SoftwareUpdateView) throws -> Data {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 680)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil; window.close() }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw UpdateAdapterError(code: "ui", detail: "Missing bitmap")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }
    @MainActor static func storageFailureCriticalityAndRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-storage-criticality-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var failAllSaves = true
        var failPhase: UpdatePhase?
        let store = UpdateStore(directory: root.appendingPathComponent("Updates")) { preferences, stateURL in
            if failAllSaves || preferences.pendingUpdate.phase == failPhase {
                throw UpdateAdapterError(code: "storage", detail: "Injected write failure")
            }
            try UpdateStore.writeAtomically(preferences, to: stateURL)
        }
        let adapter = FakeUpdateAdapter()
        let controller = DesktopUpdateController(adapter: adapter, gate: UpdateInstallGate(), store: store,
            currentVersion: "0.8.2", currentBuild: "14", automaticCheck: false)
        controller.check(manual: true)
        check(controller.storageError != nil && !controller.blocksEditing && controller.canRetrySave && adapter.checks == 0,
            "Save failure when starting a check does not block editing and offers retrySave")
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "dev.rawlab.update-storage-test.\(UUID())")!
        let legacy = UpdateChecker(defaults: defaults, currentVersion: "0.8.2", fetch: { throw URLError(.notConnectedToInternet) })
        let errorPNG = try renderPNG(SoftwareUpdateView(updates: controller, legacy: legacy))
        let notice = UpdatePresentation.storageNotice(canRetrySave: controller.canRetrySave, canRepairState: controller.canRepairState)
        check(!errorPNG.isEmpty &&
            notice == "无法读取或写入文件，请检查路径和访问权限。" &&
            notice != "无法确认更新或恢复状态，请保留全部文件并联系支持。",
            "SoftwareUpdateView renders non-blocking save notice and retry button on non-critical write failure")
        check(!controller.retrySave() && controller.storageError != nil && !controller.blocksEditing && controller.canRetrySave,
            "Repeated non-critical save failure stays unblocked and retryable")
        failAllSaves = false
        check(controller.retrySave() && controller.storageError == nil && !controller.canRetrySave && controller.canCheck,
            "Retrying save clears non-critical storage error and restores update checks")
        let clearedPNG = try renderPNG(SoftwareUpdateView(updates: controller, legacy: legacy))
        check(!clearedPNG.isEmpty && clearedPNG != errorPNG,
            "Clearing non-critical storage error updates the rendered SoftwareUpdateView")
        let release = UpdateDescriptor(version: "0.9.1", build: "19", platform: "macos", architecture: "arm64", channel: "stable",
            assetURL: "https://example.invalid/update.zip", size: 12, sha256: nil, notes: "")
        controller.check(manual: true); adapter.send(.found(release)); controller.download()
        adapter.send(.preparing); adapter.hasPreparedInstaller = true; adapter.send(.verified)
        failPhase = .installing
        controller.choose(.restartNow)
        for _ in 0..<400 where controller.preparingInstallation || controller.storageError == nil { try await Task.sleep(for: .milliseconds(10)) }
        check(controller.storageError != nil && controller.blocksEditing && !controller.canRetrySave && !controller.canCheck && adapter.installs == 0,
            "Save failure when recording installing locks editing and blocks retry")
        let pendingStore = UpdateStore(directory: root.appendingPathComponent("PendingRestartUpdates")) { preferences, stateURL in
            if preferences.pendingUpdate.phase == .pendingRestart {
                throw UpdateAdapterError(code: "storage", detail: "Injected pendingRestart write failure")
            }
            try UpdateStore.writeAtomically(preferences, to: stateURL)
        }
        let pendingAdapter = FakeUpdateAdapter()
        let pendingController = DesktopUpdateController(adapter: pendingAdapter, gate: UpdateInstallGate(), store: pendingStore,
            currentVersion: "0.8.2", currentBuild: "14", automaticCheck: false)
        pendingController.check(manual: true); pendingAdapter.send(.found(release)); pendingController.download()
        pendingAdapter.send(.preparing); pendingAdapter.hasPreparedInstaller = true; pendingAdapter.send(.verified)
        pendingController.choose(.restartNow)
        for _ in 0..<400 where pendingController.preparingInstallation || pendingController.storageError == nil { try await Task.sleep(for: .milliseconds(10)) }
        check(pendingController.storageError != nil && pendingController.blocksEditing && !pendingController.canRetrySave,
            "Save failure when recording pendingRestart locks editing")
        let recoveryRoot = root.appendingPathComponent("Recovery")
        let edits = recoveryRoot.appendingPathComponent("Edits")
        try FileManager.default.createDirectory(at: edits, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: edits.appendingPathComponent("photo.json"))
        var failRecoverySave = false
        let recoveryStore = UpdateStore(directory: recoveryRoot.appendingPathComponent("Updates")) { preferences, stateURL in
            if failRecoverySave { throw UpdateAdapterError(code: "storage", detail: "Injected recovery write failure") }
            try UpdateStore.writeAtomically(preferences, to: stateURL)
        }
        let backup = try UpdateDataBackup(dataRoot: recoveryRoot, updateRoot: recoveryStore.directory)
            .create(previous: "0.8.2", target: "0.9.1", previousBuild: "14")
        var failed = UpdatePreferences(); var token = failed.pendingUpdate.beginCheck()
        _ = failed.pendingUpdate.found(release, token: token); token = failed.pendingUpdate.beginDownload()!
        _ = failed.pendingUpdate.preparing(token: token); _ = failed.pendingUpdate.verified(token: token)
        _ = failed.pendingUpdate.choose(.onQuit); _ = failed.pendingUpdate.admit(blockedBy: [])
        failed.pendingUpdate.backupPath = backup.path; failed.pendingUpdate.previousVersion = "0.8.2"; failed.pendingUpdate.previousBuild = "14"
        _ = failed.pendingUpdate.installing(token: token); _ = failed.pendingUpdate.fail("install", detail: "", token: token)
        try recoveryStore.save(failed)
        failRecoverySave = true
        let recovering = DesktopUpdateController(adapter: FakeUpdateAdapter(), gate: UpdateInstallGate(), store: recoveryStore,
            currentVersion: "0.8.2", currentBuild: "14")
        await recovering.restorePreviousData()
        check(recovering.storageError != nil && recovering.blocksEditing && !recovering.canRetrySave,
            "Save failure during data recovery locks editing")
    }

    @MainActor static func preHandoffFailureAllowsRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-prehandoff-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let edits = root.appendingPathComponent("Edits"); try FileManager.default.createDirectory(at: edits, withIntermediateDirectories: true)
        try Data("committed edit".utf8).write(to: edits.appendingPathComponent("photo.json"))
        let store = UpdateStore(directory: root.appendingPathComponent("Updates")), adapter = FakeUpdateAdapter()
        let backupsDir = store.directory.appendingPathComponent("Backups")
        let controller = DesktopUpdateController(adapter: adapter, gate: UpdateInstallGate(), store: store, currentVersion: "0.8.2", currentBuild: "14")
        let release = UpdateDescriptor(version: "0.9.1", build: "19", platform: "macos", architecture: "arm64", channel: "stable",
            assetURL: "https://example.invalid/update.zip", size: 12, sha256: nil, notes: "")
        var sawBackupBeforeHandoff = false
        adapter.onPrepareInstall = {
            sawBackupBeforeHandoff = ((try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []).count == 1
        }
        controller.check(manual: true); adapter.send(.found(release)); controller.download()
        adapter.send(.preparing); adapter.hasPreparedInstaller = true; adapter.send(.verified)
        adapter.trustError = UpdateAdapterError(code: "identity", detail: "Injected pre-handoff host failure")
        controller.choose(.restartNow)
        for _ in 0..<400 where controller.state.phase != .failed || controller.preparingInstallation { try await Task.sleep(for: .milliseconds(10)) }
        let remainingBackups = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        check(sawBackupBeforeHandoff && controller.state.failure?.stage == .readyToInstall &&
            !controller.requiresRecovery && !controller.blocksEditing &&
            controller.state.backupPath == nil && remainingBackups.isEmpty && controller.canCheck && adapter.installs == 0,
            "Pre-handoff validation failure stays out of recovery, unlocks editing, discards backup and permits retry")
        adapter.trustError = nil; adapter.onPrepareInstall = nil
        controller.retry(); adapter.send(.found(release))
        check(controller.state.phase == .downloading && adapter.downloads == 2,
            "Explicit retry recovers cleanly after a pre-handoff validation failure")
        adapter.send(.preparing); adapter.hasPreparedInstaller = true; adapter.send(.verified)
        adapter.hasPreparedInstaller = false
        controller.choose(.onQuit)
        let allowed = await withCheckedContinuation { continuation in
            controller.prepareForQuit { continuation.resume(returning: $0) }
        }
        let remainingAfterQuit = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        check(allowed && controller.state.phase == .failed && controller.state.failure?.stage == .readyToInstall &&
            !controller.requiresRecovery && !controller.blocksEditing && remainingAfterQuit.isEmpty && controller.canCheck,
            "Missing prepared installer callback before Sparkle handoff also records readyToInstall failure without locking editing")
    }

    @MainActor static func presetAndLookGateAndHealthCodes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-preset-look-gate-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let presetsDir = root.appendingPathComponent("Presets"), looksDir = root.appendingPathComponent("Looks")
        try FileManager.default.createDirectory(at: presetsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: looksDir, withIntermediateDirectories: true)
        try Data("{corrupt".utf8).write(to: presetsDir.appendingPathComponent("presets.json"))
        let model = EditorModel(presetDirectory: presetsDir, lookDirectory: looksDir)
        let gate = UpdateInstallGate(), adapter = FakeUpdateAdapter()
        model.registerUpdateGate(gate)
        let controller = DesktopUpdateController(adapter: adapter, gate: gate,
            store: UpdateStore(directory: root.appendingPathComponent("Updates")), currentVersion: "0.8.2", currentBuild: "14", automaticCheck: false)
        let release = UpdateDescriptor(version: "0.9.1", build: "19", platform: "macos", architecture: "arm64", channel: "stable",
            assetURL: "https://example.invalid/update.zip", size: 12, sha256: nil, notes: "")
        controller.check(manual: true); adapter.send(.found(release)); controller.download()
        adapter.send(.preparing); adapter.hasPreparedInstaller = true; adapter.send(.verified)
        controller.choose(.restartNow)
        try await Task.sleep(for: .milliseconds(50))
        check(gate.blockers().contains("presets") &&
            controller.state.blockers.contains("presets") &&
            UpdatePresentation.blocker("presets") == "预设库无法读取，原文件保持不变。请从备份恢复后重试。" &&
            controller.state.phase == .waitingForTasks && !controller.blocksEditing && adapter.installs == 0,
            "Corrupt presets.json blocks pre-install gate with presets reason before installing")
        try FileManager.default.removeItem(at: presetsDir.appendingPathComponent("presets.json"))
        try Data("{corrupt".utf8).write(to: looksDir.appendingPathComponent("registry.json"))
        controller.choose(.afterTasks)
        controller.refreshGate()
        try await Task.sleep(for: .milliseconds(30))
        check(gate.blockers().contains("looks") && !gate.blockers().contains("presets") &&
            controller.state.blockers.contains("looks") &&
            UpdatePresentation.blocker("looks") == "无法读取已保存的外观库，原有记录未被覆盖。" &&
            controller.state.phase == .waitingForTasks && !controller.preparingInstallation && adapter.installs == 0,
            "Corrupt Looks/registry.json blocks pre-install gate with looks reason even when corrupted mid-session")

        var codes: [String: String] = [:]
        for item in ["presets", "looks", "edits", "journal"] {
            let caseRoot = root.appendingPathComponent("health-\(item)")
            let casePresets = caseRoot.appendingPathComponent("Presets"), caseLooks = caseRoot.appendingPathComponent("Looks")
            try FileManager.default.createDirectory(at: casePresets, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: caseLooks, withIntermediateDirectories: true)
            if item == "presets" { try Data("{corrupt".utf8).write(to: casePresets.appendingPathComponent("presets.json")) }
            if item == "looks" { try Data("{corrupt".utf8).write(to: caseLooks.appendingPathComponent("registry.json")) }
            let candidate = EditorModel(presetDirectory: casePresets, lookDirectory: caseLooks)
            if item == "edits" { candidate.editStore = nil }
            if item == "journal" { candidate.updateJournalLoadFailed = true }
            let store = UpdateStore(directory: caseRoot.appendingPathComponent("Updates"))
            let backup = try UpdateDataBackup(dataRoot: caseRoot, updateRoot: store.directory)
                .create(previous: "0.8.2", target: "0.9.1", previousBuild: "14")
            var pending = UpdatePreferences(); var token = pending.pendingUpdate.beginCheck()
            _ = pending.pendingUpdate.found(release, token: token); token = pending.pendingUpdate.beginDownload()!
            _ = pending.pendingUpdate.preparing(token: token); _ = pending.pendingUpdate.verified(token: token)
            _ = pending.pendingUpdate.choose(.restartNow); _ = pending.pendingUpdate.admit(blockedBy: [])
            pending.pendingUpdate.backupPath = backup.path; pending.pendingUpdate.previousVersion = "0.8.2"; pending.pendingUpdate.previousBuild = "14"
            _ = pending.pendingUpdate.installing(token: token); _ = pending.pendingUpdate.awaitingRestart(token: token)
            try store.save(pending)
            let postInstall = DesktopUpdateController(adapter: FakeUpdateAdapter(), gate: UpdateInstallGate(), store: store,
                currentVersion: "0.9.1", currentBuild: "19")
            let failures = candidate.updateDataFailures
            await postInstall.finishStartupHealthCheck(healthy: failures.isEmpty, dataFailures: failures)
            codes[item] = postInstall.state.failure?.code ?? ""
            check(postInstall.state.failure?.detail == item, "Startup health check failure detail records failed item: \(item)")
        }
        check(codes["presets"] == "data_presets" && codes["looks"] == "data_looks" &&
            codes["edits"] == "data_edits" && codes["journal"] == "data_journal" &&
            Set(codes.values).count == 4,
            "Startup health check failure codes distinguish presets, looks, edits and journal data causes")
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
        let beforeQuit = controller.state
        var allowed: Bool?
        controller.prepareForQuit { allowed = $0 }
        check(allowed == true && controller.state == beforeQuit,
            "Normal quit preserves an installation dispatch failure for recovery after reopening")
        let reopened = DesktopUpdateController(adapter: FakeUpdateAdapter(), gate: UpdateInstallGate(), store: store, currentVersion: "0.8.2", currentBuild: "14")
        check(reopened.blocksEditing && reopened.canRestorePreviousData, "Reopening offers recovery while editing remains blocked")
        await reopened.restorePreviousData()
        check(reopened.blocksEditing && reopened.recoveryNeedsRestart, "Restored data remains blocked until the next launch")
    }

    @MainActor static func malformedFailureStartup(store: UpdateStore, original: UpdatePreferences) async throws {
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
            await reopened.finishStartupHealthCheck(healthy: true)
            check(reopened.storageError != nil && !reopened.canCheck && !reopened.canChooseInstall && !reopened.canRepairState,
                "Malformed installation failure blocks startup and state reset: \(name)")
            let preserved = try Data(contentsOf: store.stateURL)
            check(preserved == bytes, "Blocked startup preserves the damaged failure record: \(name)")
        }
    }

    @MainActor static func stateRepair() async throws {
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
        await damaged.finishStartupHealthCheck(healthy: true)
        check(damaged.storageError == nil && damaged.recoveryNeedsRestart && damaged.requiresRecovery && !damaged.canCheck && adapter.installs == 0,
            "Repair cannot reopen editing or install in the current process")
        check(!damaged.preferences.automaticCheck && !damaged.preferences.automaticInstall && damaged.preferences.stateRepairReceipt != nil,
            "Recovery actions cannot enable automatic updates or clear the startup receipt")
        let unhealthy = DesktopUpdateController(adapter: adapter, gate: UpdateInstallGate(), store: store, currentVersion: "0.8.2", currentBuild: "14")
        check(unhealthy.requiresStartupHealthCheck && !unhealthy.requiresRecovery, "Reopening repaired state requires data health validation")
        await unhealthy.finishStartupHealthCheck(healthy: false)
        check(unhealthy.requiresRecovery && !unhealthy.canCheck && unhealthy.preferences.stateRepairReceipt != nil,
            "Unhealthy user data remains blocked after repair")
        let healthy = DesktopUpdateController(adapter: adapter, gate: UpdateInstallGate(), store: store, currentVersion: "0.8.2", currentBuild: "14")
        await healthy.finishStartupHealthCheck(healthy: true)
        check(!healthy.requiresStartupHealthCheck && !healthy.requiresRecovery && healthy.canCheck && !healthy.preferences.automaticInstall,
            "Only a fresh healthy startup completes explicit state repair")
    }
}
