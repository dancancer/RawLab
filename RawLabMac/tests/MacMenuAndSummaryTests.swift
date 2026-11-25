import RawLabKit
import AppKit
import Combine
import SwiftUI

@main
struct MacMenuAndSummaryTests {
    static var count = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
        count += 1
        print("PASS: \(message)")
    }

    @MainActor
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-mac-menu-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 1. FileMenuCommands reactivity & primary export format on HDR switches
        let model = EditorModel(
            lookDirectory: root.appendingPathComponent("looks"),
            editDirectory: root.appendingPathComponent("edits"),
            batchDirectory: root.appendingPathComponent("batch"),
            presetDirectory: root.appendingPathComponent("presets")
        )
        let fileMenu = FileMenuCommands(model: model, openBatchSelection: {}, openBatchExport: {})
        _ = fileMenu.body
        check(FileMenuCommands.primaryExportFormat(isHDREditing: false) == .jpeg,
              "SDR file menu routes Cmd+Shift+E to standard JPEG")
        check(FileMenuCommands.primaryExportFormat(isHDREditing: true) == .hdrJPEG,
              "HDR file menu routes Cmd+Shift+E to HDR JPEG")

        var changeNotifications = 0
        let cancellable = model.objectWillChange.sink { _ in changeNotifications += 1 }
        _ = cancellable
        model.settings.hdr = HDRSettings()
        check(changeNotifications > 0 && FileMenuCommands.primaryExportFormat(isHDREditing: model.settings.isHDREditing) == .hdrJPEG,
              "Enabling HDR notifies FileMenuCommands observer to update export menu items")
        let countAfterEnable = changeNotifications
        model.settings.hdr = nil
        check(changeNotifications > countAfterEnable && FileMenuCommands.primaryExportFormat(isHDREditing: model.settings.isHDREditing) == .jpeg,
              "Disabling HDR notifies FileMenuCommands observer to restore SDR export menu items")

        // 2. ViewCommands scoping strictly to the active editor window without attached sheets
        let viewState = MacViewCommandState()
        _ = ViewCommands(model: model, commands: viewState).body
        check(!viewState.editorWindowActive, "View commands start inactive before editor window attaches")

        let editorWindow = NSWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        editorWindow.isReleasedWhenClosed = false
        let batchWindow = NSWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: 480, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        batchWindow.isReleasedWhenClosed = false
        let sheetWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 140),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheetWindow.isReleasedWhenClosed = false
        defer {
            editorWindow.contentView = nil
            editorWindow.close()
            batchWindow.close()
            sheetWindow.close()
        }

        var trackedWindow: NSWindow?
        let guardHost = MacGeometryWindowGuard(model: model) { trackedWindow = $0 }
        let guardView = MacGeometryWindowGuard.GuardView(model: model)
        guardView.onWindowChange = guardHost.onWindowChange
        editorWindow.contentView = NSView(frame: editorWindow.contentLayoutRect)
        editorWindow.contentView?.addSubview(guardView)
        check(trackedWindow === editorWindow, "Window guard reports editor NSWindow attachment")

        viewState.attachEditorWindow(trackedWindow)
        viewState.refreshEditorWindowActive(keyWindow: editorWindow)
        check(viewState.editorWindowActive, "View commands become active when editor NSWindow is key without a sheet")

        var invoked = 0
        viewState.canZoom = true
        viewState.zoomIn = { invoked += 1 }
        viewState.performIfActive(viewState.canZoom, keyWindow: editorWindow, action: viewState.zoomIn)
        check(invoked == 1, "View commands execute when editor NSWindow is key")

        viewState.performIfActive(viewState.canZoom, keyWindow: batchWindow, action: viewState.zoomIn)
        check(invoked == 1 && !viewState.editorWindowActive,
              "Secondary NSWindow (Batch Selection/Export) deactivates and blocks editor view commands")
        check(!MacViewCommandState.isEditorWindowActive(editorWindow: editorWindow, keyWindow: batchWindow),
              "Window identity check rejects non-panel secondary windows")

        editorWindow.orderBack(nil)
        editorWindow.beginSheet(sheetWindow)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check(!MacViewCommandState.isEditorWindowActive(editorWindow: editorWindow, keyWindow: editorWindow),
              "Attached sheet blocks editor view commands even if keyWindow refers to the editor")
        viewState.performIfActive(viewState.canZoom, keyWindow: editorWindow, action: viewState.zoomIn)
        check(invoked == 1 && !viewState.editorWindowActive,
              "Sheet presentation sets editorWindowActive to false and blocks view command invocation")
        editorWindow.endSheet(sheetWindow)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        viewState.performIfActive(viewState.canZoom, keyWindow: editorWindow, action: viewState.zoomIn)
        check(invoked == 2 && viewState.editorWindowActive,
              "Ending sheet restores editor view command execution")

        MacGeometryWindowGuard.dismantleNSView(guardView, coordinator: ())
        check(trackedWindow == nil, "Window guard clears tracked window on dismantle")

        // 3. BatchExportView SDR summary deduplication
        var sdr = Adjustments()
        sdr.exposure = 1.25
        sdr.temperature = 6100
        sdr.tint = 8
        check(MacBatchSettingsSummaryView.showsSDRBaselineHeaders(for: sdr, omitTopSummaryFields: false),
              "Full summary renders SDR exposure-baseline and WB headers")
        check(!MacBatchSettingsSummaryView.showsSDRBaselineHeaders(for: sdr, omitTopSummaryFields: true),
              "Deduplicated Batch Export disclosure omits repeated SDR baseline and WB headers")
        let fullParams = MacBatchSettingsSummaryView.summaryParameters(for: sdr, omitTopSummaryFields: false)
        let dedupParams = MacBatchSettingsSummaryView.summaryParameters(for: sdr, omitTopSummaryFields: true)
        check(fullParams.contains(.exposure) && fullParams.contains(.toneCurve),
              "Full SDR summary includes exposure and legacy scalar tone curve when curve mode is legacy")
        check(!dedupParams.contains(.exposure) && dedupParams.contains(.temperature) && dedupParams.contains(.highlights) && dedupParams.contains(.toneCurve),
              "Deduplicated Batch Export disclosure omits repeated exposure row while keeping remaining adjustments")

        var customCurveSDR = sdr
        customCurveSDR.curveSettings = .identity
        let fullCustomParams = MacBatchSettingsSummaryView.summaryParameters(for: customCurveSDR, omitTopSummaryFields: false)
        let dedupCustomParams = MacBatchSettingsSummaryView.summaryParameters(for: customCurveSDR, omitTopSummaryFields: true)
        check(fullCustomParams.contains(.exposure) && !fullCustomParams.contains(.toneCurve) &&
              !dedupCustomParams.contains(.exposure) && !dedupCustomParams.contains(.toneCurve),
              "Custom/parametric curve hides legacy scalar tone curve while Batch Export disclosure still deduplicates exposure")

        var hdr = Adjustments()
        hdr.hdr = HDRSettings()
        check(!MacBatchSettingsSummaryView.showsSDRBaselineHeaders(for: hdr, omitTopSummaryFields: true) &&
              MacBatchSettingsSummaryView.summaryParameters(for: hdr, omitTopSummaryFields: true).contains(.exposure),
              "HDR summary retains HDR exposure parameter regardless of omitTopSummaryFields")

        print("PASS: \(count) Mac menu command and summary checks")
    }
}
