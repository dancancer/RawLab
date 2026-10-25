import AppKit
import SwiftUI

@main struct SoftwareUpdateUITests {
    @MainActor struct GuardedEditor: View {
        let model: EditorModel
        @ObservedObject var updates: DesktopUpdateController
        var body: some View { EditorView(model: model).disabled(updates.blocksEditing) }
    }
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw RenderError.failed(message) }; print("PASS: \(message)")
    }
    @MainActor static func settle(_ model: EditorModel) async throws {
        try await Task.sleep(for: .milliseconds(350))
        for _ in 0..<600 {
            if !model.busy, !model.workerActive, model.result != nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw RenderError.failed("Native editor render timed out")
    }
    @MainActor static func fields(_ view: NSView) -> [NumericTextField] {
        (view as? NumericTextField).map { [$0] } ?? view.subviews.flatMap { fields($0) }
    }
    @MainActor static func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
    }
    @MainActor static func window<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view); host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; host.layoutSubtreeIfNeeded()
        return (window, host)
    }
    @MainActor static func run() async throws {
        guard CommandLine.arguments.count == 3 else { throw RenderError.failed("Pass a fixture and output directory") }
        let output = URL(fileURLWithPath: CommandLine.arguments[2]); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var lease: MacUpdateRunLease? = try MacUpdateRunLease(directory: output.appendingPathComponent("lock"))
        var rejected = false
        do { _ = try MacUpdateRunLease(directory: output.appendingPathComponent("lock")) } catch { rejected = true }
        try check(lease != nil && rejected, "Production run lease rejects a second writer before editing")
        lease = nil
        lease = try MacUpdateRunLease(directory: output.appendingPathComponent("lock")); lease = nil
        let state = output.appendingPathComponent("state"); let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let photo = output.appendingPathComponent("source." + source.pathExtension); try FileManager.default.copyItem(at: source, to: photo)
        UserDefaults.standard.setVolatileDomain([L10n.preferenceKey: "en", "photoFolders": [String]()], forName: UserDefaults.argumentDomain)
        let model = EditorModel(lookDirectory: state.appendingPathComponent("Looks"), editDirectory: state.appendingPathComponent("Edits"),
            batchDirectory: state.appendingPathComponent("Batch"), presetDirectory: state.appendingPathComponent("Presets"))
        let adapter = Adapter(), gate = UpdateInstallGate()
        model.registerUpdateGate(gate)
        let updates = DesktopUpdateController(adapter: adapter, gate: gate, store: UpdateStore(directory: state.appendingPathComponent("Updates")), currentVersion: "0.8.2", currentBuild: "14", automaticCheck: false)
        let defaults = UserDefaults(suiteName: "dev.rawlab.updates-ui.\(UUID())")!
        let legacy = UpdateChecker(defaults: defaults, currentVersion: "0.8.2", fetch: { throw URLError(.notConnectedToInternet) })
        model.open(photo); try await settle(model); model.selectAdjustmentTool(.exposure)
        let (editorWindow, editor) = window(GuardedEditor(model: model, updates: updates), width: 1200, height: 850)
        defer { editorWindow.contentView = nil; editorWindow.close() }
        try await settle(model); editor.layoutSubtreeIfNeeded()
        guard let field = fields(editor).first(where: { $0.isEnabled }),
              let coordinator = field.delegate as? ParameterValueField.Coordinator else { throw RenderError.failed("Actual editor numeric field missing") }
        for draft in ["1.25", "-"] {
            editorWindow.makeFirstResponder(field)
            field.stringValue = draft; field.currentEditor()?.string = draft
            coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            let saved = try model.editStore!.versionedState(for: photo), count = model.adjustmentSession!.transactions.count
            let original = model.settings
            ParameterValueField.preserveInputsForUpdateNavigation()
            let (updateWindow, _) = window(SoftwareUpdateView(updates: updates, legacy: legacy), width: 560, height: 600)
            editorWindow.makeFirstResponder(nil); updateWindow.makeFirstResponder(updateWindow.contentView)
            updates.check(manual: true); adapter.send(.found(adapter.release)); updates.download()
            try await Task.sleep(for: .milliseconds(100)); editor.layoutSubtreeIfNeeded()
            try check(coordinator.dirty && field.stringValue == draft && model.settings == original &&
                model.editStore!.versionedState(for: photo) == saved && model.adjustmentSession!.transactions.count == count,
                "Actual editor field survives opening, checking and downloading: \(draft)")
            try check(gate.blockers().contains("draft"), "Production install gate sees suspended native input")
            updates.cancel(); updateWindow.contentView = nil; updateWindow.close(); editorWindow.makeFirstResponder(field)
            try check(coordinator.dirty && field.stringValue == draft, "Closing the update window retains the pending input")
            coordinator.cancel(); editorWindow.makeFirstResponder(nil)
        }
        try check(model.beginGeometryDraft(tab: .perspective), "Real geometry draft is active")
        model.updateGeometryDraft { $0.perspectiveHorizontal = 0.2 }; try await settle(model)
        let draft = model.geometryDraft, saved = try model.editStore!.versionedState(for: photo)
        let history = model.adjustmentSession!.transactions.count
        updates.check(manual: true); adapter.send(.found(adapter.release)); updates.download(); adapter.send(.preparing); adapter.send(.verified)
        updates.choose(.onQuit)
        try check(updates.state.phase == .waitingForTasks && updates.state.blockers.contains("draft") && adapter.installs == 0 &&
            model.geometryDraft == draft && model.editStore!.versionedState(for: photo) == saved && model.adjustmentSession!.transactions.count == history,
            "Production geometry draft blocks an explicit install without applying, discarding or saving it")
        updates.cancel(); model.cancelGeometryDraft(); try await settle(model)
        for language in ["zh-Hans", "en", "de", "fr", "ja", "es"] {
            UserDefaults.standard.setVolatileDomain([L10n.preferenceKey: language, "photoFolders": [String]()], forName: UserDefaults.argumentDomain)
            let (dialog, host) = window(SoftwareUpdateView(updates: updates, legacy: legacy).environment(\.locale, Locale(identifier: language)).dynamicTypeSize(.accessibility3)
                .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark), width: 560, height: 680)
            try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw RenderError.failed("No native update bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("updates-\(language).png"))
            try check(L10n.text("软件更新") != "软件更新" || language == "zh-Hans", "Software update title is localized: \(language)")
            dialog.contentView = nil; dialog.close()
        }
        UserDefaults.standard.setVolatileDomain([L10n.preferenceKey: "en"], forName: UserDefaults.argumentDomain)
        let beforeFailure = try model.editStore!.versionedState(for: photo)
        updates.check(manual: true); adapter.send(.found(adapter.release)); updates.download(); adapter.send(.preparing); adapter.send(.verified)
        adapter.rejectInstall = true; updates.choose(.restartNow)
        for _ in 0..<400 where updates.state.phase != .failed || updates.preparingInstallation { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100)); editor.layoutSubtreeIfNeeded()
        try check(updates.state.failure?.stage == .installing && !fields(editor).contains(where: { $0.isEnabled }) &&
            model.editStore!.versionedState(for: photo) == beforeFailure,
            "A failed installer dispatch disables real editor fields and preserves saved edits")
        let recoveryRoot = output.appendingPathComponent("recovery"), recoveryStore = UpdateStore(directory: output.appendingPathComponent("recovery/Updates"))
        let original = recoveryRoot.appendingPathComponent("Edits/photo.json")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("previous edit".utf8).write(to: original)
        let backup = try UpdateDataBackup(dataRoot: recoveryRoot, updateRoot: recoveryStore.directory).create(previous: "0.8.2", target: "0.9.1", previousBuild: "14")
        var pending = UpdatePreferences(); var token = pending.pendingUpdate.beginCheck()
        _ = pending.pendingUpdate.found(adapter.release, token: token); token = pending.pendingUpdate.beginDownload()!
        _ = pending.pendingUpdate.preparing(token: token); _ = pending.pendingUpdate.verified(token: token)
        _ = pending.pendingUpdate.choose(.onQuit); _ = pending.pendingUpdate.admit(blockedBy: [])
        pending.pendingUpdate.backupPath = backup.path; pending.pendingUpdate.previousVersion = "0.8.2"; pending.pendingUpdate.previousBuild = "14"
        _ = pending.pendingUpdate.installing(token: token); _ = pending.pendingUpdate.fail("test", detail: "Injected failed install", token: token)
        try recoveryStore.save(pending); try Data("new format".utf8).write(to: original)
        let recovery = DesktopUpdateController(adapter: Adapter(), gate: UpdateInstallGate(), store: recoveryStore, currentVersion: "0.8.2", currentBuild: "14")
        let (recoveryWindow, recoveryHost) = window(SoftwareUpdateView(updates: recovery, legacy: legacy).dynamicTypeSize(.accessibility3)
            .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark), width: 560, height: 680)
        try await Task.sleep(for: .milliseconds(100)); recoveryHost.layoutSubtreeIfNeeded()
        try check(recovery.canRestorePreviousData && !recovery.canCheck, "Native recovery screen exposes the explicit restore action and blocks new checks")
        guard let recoveryBitmap = recoveryHost.bitmapImageRepForCachingDisplay(in: recoveryHost.bounds) else { throw RenderError.failed("No recovery bitmap") }
        recoveryHost.cacheDisplay(in: recoveryHost.bounds, to: recoveryBitmap)
        try recoveryBitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("recovery-en.png"))
        guard let scroll = scrollViews(recoveryHost).first, let document = scroll.documentView else { throw RenderError.failed("Recovery scroll view missing") }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentSize.height)))
        scroll.reflectScrolledClipView(scroll.contentView); recoveryHost.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        recoveryHost.cacheDisplay(in: recoveryHost.bounds, to: recoveryBitmap)
        try recoveryBitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("recovery-en-scrolled.png"))
        await recovery.restorePreviousData()
        try check(recovery.recoveryNeedsRestart && recovery.state.phase != .complete && String(contentsOf: original, encoding: .utf8) == "previous edit",
            "Native recovery restores verified data and keeps editing blocked until reopening")
        recoveryWindow.contentView = nil; recoveryWindow.close()
        let repairStore = UpdateStore(directory: output.appendingPathComponent("state-repair/Updates"))
        try FileManager.default.createDirectory(at: repairStore.directory, withIntermediateDirectories: true)
        let damaged = Data("{broken".utf8); try damaged.write(to: repairStore.stateURL)
        let repair = DesktopUpdateController(adapter: Adapter(), gate: UpdateInstallGate(), store: repairStore, currentVersion: "0.8.2", currentBuild: "14")
        let (repairWindow, repairHost) = window(SoftwareUpdateView(updates: repair, legacy: legacy).dynamicTypeSize(.accessibility3), width: 560, height: 680)
        try await Task.sleep(for: .milliseconds(100)); repairHost.layoutSubtreeIfNeeded()
        try check(repair.canRepairState && !repair.canCheck, "Native damaged-state screen offers explicit repair")
        repair.repairState()
        try await Task.sleep(for: .milliseconds(100)); repairHost.layoutSubtreeIfNeeded()
        try check(repair.recoveryNeedsRestart && repair.requiresRecovery && Data(contentsOf: repair.stateArchive!) == damaged,
            "Native state repair preserves damaged bytes and remains blocked until reopening")
        let reopened = DesktopUpdateController(adapter: Adapter(), gate: UpdateInstallGate(), store: repairStore, currentVersion: "0.8.2", currentBuild: "14")
        reopened.finishStartupHealthCheck(healthy: model.updateDataHealthy)
        try check(!reopened.requiresRecovery && !reopened.requiresStartupHealthCheck, "Real editor data health completes state repair on a fresh controller")
        repairWindow.contentView = nil; repairWindow.close()
        print("PASS: actual NSHostingView controls, focus changes, draft gate and six-language layouts; no production update or install")
    }
    @MainActor final class Adapter: UpdateAdapter {
        var unavailableReason: String? { nil }
        var canCheck = true, hasAvailableRelease = false, hasPreparedInstaller = false
        var hasActiveSession: Bool { !canCheck || hasPreparedInstaller }
        var installs = 0
        var rejectInstall = false
        var token = UUID(), callback: ((UUID, UpdateAdapterEvent) -> Void)?
        let release = UpdateDescriptor(version: "0.9.1", build: "19", platform: "macos", architecture: "arm64", channel: "stable", assetURL: "https://example.invalid/update.zip", size: 12, sha256: nil, notes: "Offline UI fixture")
        func check(token: UUID, emit: @escaping (UUID, UpdateAdapterEvent) -> Void) throws { self.token = token; callback = emit; canCheck = false }
        func download(_ release: UpdateDescriptor, token: UUID) throws { self.token = token; hasAvailableRelease = false }
        func cancel() { canCheck = true; hasAvailableRelease = false; hasPreparedInstaller = false; callback?(token, .ended) }
        func install(restart: Bool) throws {
            installs += 1
            if rejectInstall { throw UpdateAdapterError(code: "install", detail: "Injected dispatch failure") }
        }
        func send(_ event: UpdateAdapterEvent) {
            if case .found = event { hasAvailableRelease = true }
            if case .verified = event { hasPreparedInstaller = true }
            callback?(token, event)
        }
    }
}
