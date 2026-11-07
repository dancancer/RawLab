import AppKit
import ImageIO

@main enum HDRHistoryTests {
    static func check(_ value: @autoclosure () -> Bool,_ message: String) { if !value() { fatalError(message) } }
    static func wait(_ message: String, _ ready: () -> Bool) {
        let deadline=Date().addingTimeInterval(30)
        while !ready() && Date()<deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
        check(ready(),message)
    }
    static func main() throws {
        let input=URL(fileURLWithPath:CommandLine.arguments[1])
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let model=EditorModel(lookDirectory:root.appendingPathComponent("looks"),editDirectory:root.appendingPathComponent("edits"),
            batchDirectory:root.appendingPathComponent("batch"))
        model.open(input)
        wait("HDR source did not open") { !model.importing && !model.busy && model.result != nil }
        check(model.settings.isHDREditing && model.sourceIsHDR,"new HDR source default missing")
        let expected=try RenderEngine().autoExposure(input,settings:model.settings)
        check(expected < 0,"the bright HDR fixture must produce a non-neutral exposure")
        let sdrExposure=model.settings.exposure
        model.autoExposure()
        wait("HDR automatic exposure did not finish") { !model.autoExposing && !model.busy }
        check(model.settings.hdr?.exposure==expected && model.settings.exposure==sdrExposure,"auto exposure changed the wrong rendition")
        check(model.saveEdits(),"first HDR edit did not save")
        let revision=model.editRevision
        model.autoExposure()
        wait("repeated HDR automatic exposure did not finish") { !model.autoExposing }
        check(model.editRevision==revision,"identical metering added an edit")
        model.undoAdjustment()
        check(model.settings.isHDREditing && model.settings.hdr?.exposure==0,"undo of the first HDR edit restored SDR defaults")
        model.redoAdjustment()
        check(model.settings.isHDREditing && model.settings.hdr?.exposure==expected,"redo lost HDR metering")
        let restored=EditorModel(lookDirectory:root.appendingPathComponent("looks"),editDirectory:root.appendingPathComponent("edits"),
            batchDirectory:root.appendingPathComponent("batch"))
        restored.open(input)
        wait("saved HDR source did not reopen") { !restored.importing && restored.result != nil }
        check(restored.settings.hdr?.exposure==expected,"reopening lost HDR metering")
        let sdr=root.appendingPathComponent("replaced-source.png")
        let destination=CGImageDestinationCreateWithURL(sdr as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,model.result!.image,nil)
        check(CGImageDestinationFinalize(destination),"SDR replacement fixture could not be written")
        var invalid=Adjustments(); invalid.hdr=HDRSettings()
        try model.editStore!.save(sdr,state:PhotoEditState(settings:invalid,filmID:""))
        model.open(sdr)
        check(model.file==input && model.sourceIsHDR,"an HDR record on a non-HDR file replaced the current canvas before decode failed")
        let next=root.appendingPathComponent("next.jpg")
        try FileManager.default.copyItem(at:input,to:next)
        model.settings.set(.exposure,to:3)
        check(model.saveEdits(),"could not save the exposure before switching photos")
        model.autoExposure()
        model.open(next)
        wait("switching photos did not finish") { !model.autoExposing && !model.importing && model.file==next }
        let previous=try model.editStore!.versionedState(for:input)
        check(previous.state?.settings.hdr?.exposure==3 && model.settings.hdr?.exposure==0,
              "a stale automatic exposure changed an edit during photo switching")
        print("PASS Mac HDR automatic exposure, undo/redo and reopening preserve the source default mode")

        let fixture = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RAWLAB_TEST_CAMERA_RAW"]!)
        let camera = root.appendingPathComponent("source.dng"), target = root.appendingPathComponent("target.dng")
        for url in [camera, target] { try FileManager.default.copyItem(at: fixture, to: url) }
        model.open(camera)
        wait("Bayer source did not open") { model.file == camera && model.canExport }
        model.setHDREditing(true)
        wait("Bayer source did not enter HDR") { model.settings.isHDREditing && model.canExport }
        check(model.sourceIsBayerHDR && model.adjustmentTransferFields.contains(.hdrCameraDevelopment), "Bayer source lost its transfer scope")
        var development = HDRCameraDevelopmentSettings(); development.fbddLevel = 2
        model.applyHDRCameraDevelopment(development)
        wait("Bayer source edit did not commit") { model.settings.hdr?.cameraDevelopmentSettings.fbddLevel == 2 && model.canExport }
        let payload = try model.copyAdjustments(scope: .custom([.hdrCameraDevelopment]))

        model.open(target)
        wait("Bayer target did not open") { model.file == target && model.canExport }
        model.setHDREditing(true)
        wait("Bayer target did not enter HDR") { model.settings.isHDREditing && model.canExport }
        let before = try model.editStore!.versionedState(for: target)
        let mixed = try model.prepareAdjustmentPaste(payload: payload, targets: [target, next])
        check(mixed.targets.count == 2 && mixed.targets[0].error == nil && mixed.targets[1].error != nil,
              "Camera transfer accepted the gain-map target or rejected the Bayer target")
        model.applyAdjustmentPaste(mixed)
        let unchanged = try model.editStore!.versionedState(for: target)
        check(unchanged == before, "Failed camera transfer wrote the compatible target before review")

        let prepared = try model.prepareAdjustmentPaste(payload: payload, targets: [target])
        model.applyAdjustmentPaste(prepared)
        let saved = try model.editStore!.versionedState(for: target)
        check(saved.state?.settings.hdr?.cameraDevelopmentSettings.fbddLevel == 2 &&
              saved.state?.settings.hdr?.processingVersion == 1, "Camera paste did not persist the FBDD edit at rendering version 1")
        print("PASS Mac camera HDR clipboard, Bayer native preflight, incompatible target blocking and persisted FBDD")
    }
}
