import AppKit
import ImageIO

@main enum HDRHistoryTests {
    static func check(_ value: @autoclosure () -> Bool,_ message: String) { if !value() { fatalError(message) } }
    static func main() throws {
        let input=URL(fileURLWithPath:CommandLine.arguments[1])
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let model=EditorModel(lookDirectory:root.appendingPathComponent("looks"),editDirectory:root.appendingPathComponent("edits"),
            batchDirectory:root.appendingPathComponent("batch"))
        model.open(input)
        let deadline=Date().addingTimeInterval(30)
        while (model.importing || model.busy || model.result==nil) && Date()<deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
        check(model.settings.isHDREditing && model.sourceIsHDR,"new HDR source default missing")
        model.setInteracting(true); model.settings.hdr?.exposure=1; model.setInteracting(false)
        check(model.saveEdits(),"first HDR edit did not save")
        model.undoAdjustment()
        check(model.settings.isHDREditing && model.settings.hdr?.exposure==0,"undo of the first HDR edit restored SDR defaults")
        model.redoAdjustment()
        check(model.settings.isHDREditing && model.settings.hdr?.exposure==1,"redo lost HDR editing mode")
        let sdr=root.appendingPathComponent("replaced-source.png")
        let destination=CGImageDestinationCreateWithURL(sdr as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,model.result!.image,nil)
        check(CGImageDestinationFinalize(destination),"SDR replacement fixture could not be written")
        var invalid=Adjustments(); invalid.hdr=HDRSettings()
        try model.editStore!.save(sdr,state:PhotoEditState(settings:invalid,filmID:""))
        model.open(sdr)
        check(model.file==input && model.sourceIsHDR,"an HDR record on a non-HDR file replaced the current canvas before decode failed")
        print("PASS Mac first HDR edit undo/redo preserves the source default mode")
    }
}
