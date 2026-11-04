import AppKit
import Foundation
import ImageIO

@main enum HDRBatchTests {
    static func check(_ condition: @autoclosure () -> Bool,_ message: String) { if !condition() { fatalError(message) } }
    static func main() throws {
        let input=URL(fileURLWithPath:CommandLine.arguments[1])
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let legacy=directory.appendingPathComponent("legacy.jpg")
        try FileManager.default.copyItem(at:input,to:legacy)
        let store=try EditPersistence(directory:directory.appendingPathComponent("edits"))
        var old=Adjustments(); old.exposure = -0.5
        try store.save(legacy,state:PhotoEditState(settings:old,filmID:""))
        let before=try store.versionedState(for:legacy)
        var source=Adjustments(); source.hdr=HDRSettings(); source.hdr?.exposure=1
        let preparer=MacHDRBatchPreparation(source:input,settings:source,store:store,films:[])
        if let path = ProcessInfo.processInfo.environment["RAWLAB_TEST_PRORAW"] {
            let raw = URL(fileURLWithPath: path)
            let info = try HDRSourceInfo.probeRAW(raw)
            check(info?.proRAW != nil, "ProRAW fixture was not recognized")
            let item = try BatchExportItem(url: raw)
            let fresh = try preparer.prepare(item, ordinal: 2, format: .jpeg, longEdge: nil)
            check(!fresh.settings.isHDREditing && fresh.settings.exposure == 1,
                  "fresh ProRAW batch target was silently upgraded to HDR")
            var saved = Adjustments(); saved.exposure = -2; saved.hdr = HDRSettings()
            try store.save(raw, state: PhotoEditState(settings: saved, filmID: ""))
            let beforeRaw = try store.versionedState(for: raw)
            let hdr = try preparer.prepare(item, ordinal: 2, format: .hdrJPEG, longEdge: nil)
            check(hdr.settings.isHDREditing && hdr.settings.hdr?.exposure == 1 && hdr.settings.exposure == -2,
                  "saved ProRAW HDR batch target lost its mode or dormant SDR state")
            let afterRaw = try store.versionedState(for: raw)
            check(afterRaw == beforeRaw, "ProRAW batch preparation wrote target records")
            var editedSource = source
            editedSource.hdr?.geometry.quarterTurns = 1
            editedSource.hdr?.geometry.straightenDegrees = 7
            editedSource.hdr?.geometry.cropWidth = 0.5
            let streamPreparation = MacHDRBatchPreparation(source: input, settings: editedSource, store: store, films: [])
            for format in [ExportFormat.hdrJPEG, .jpeg] {
                var streamJob = BatchExportJob(source: input, settings: editedSource, look: nil, lookName: "HDR")
                var target = item; target.selected = true
                streamJob.items = [target]; streamJob.outputDirectory = directory
                streamJob.longEdge = 512; streamJob.format = format
                let streamModel = BatchExportModel(job: streamJob,
                    journal: BatchJournal(directory: directory.appendingPathComponent(UUID().uuidString)),
                    hdrPreparation: streamPreparation)
                streamModel.start()
                let deadline = Date().addingTimeInterval(90)
                while streamModel.running && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
                check(!streamModel.running && streamModel.error == nil && streamModel.job.succeededCount == 1,
                      "ProRAW stream batch failed: \(streamModel.error ?? "timeout")")
                let output = streamModel.job.items[0].output!
                let probe = try HDRSourceInfo.probe(output)
                check((probe != nil) == (format == .hdrJPEG), "ProRAW batch rendition routing differs")
                let image = CGImageSourceCreateWithURL(output as CFURL, nil)!
                let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil)! as NSDictionary
                check(max(properties[kCGImagePropertyPixelWidth] as! Int, properties[kCGImagePropertyPixelHeight] as! Int) == 512,
                      "ProRAW batch skipped geometry/resize")
                check(properties[kCGImagePropertyOrientation] as? Int == 1, "ProRAW batch output orientation differs")
            }
            print("PASS ProRAW batch capability, frozen target modes and record isolation")
            print("PASS Mac ProRAW stream Engine routing and HDR/SDR batch file publication")
        }
        var first=try BatchExportItem(url:input),second=try BatchExportItem(url:legacy)
        first.selected=true; second.selected=true
        let a=try preparer.prepare(first,ordinal:0,format:.jpeg,longEdge:32)
        let b=try preparer.prepare(second,ordinal:1,format:.jpeg,longEdge:32)
        check(a.settings.isHDREditing && a.settings.hdr?.exposure==1,"new HDR target did not get its own HDR defaults")
        check(!b.settings.isHDREditing && b.settings.exposure==1 && b.settings.hdr==nil,"legacy SDR target inherited HDR mode")
        let after=try store.versionedState(for:legacy)
        check(after==before,"batch preparation modified target records")
        var wb=source; wb.hdr?.tint=15
        let incompatible=MacHDRBatchPreparation(source:input,settings:wb,store:store,films:[])
        do { _ = try incompatible.prepare(second,ordinal:1,format:.jpeg,longEdge:32); fatalError("relative HDR WB partially applied to SDR target") }
        catch AdjustmentTransferError.incompatible {}
        var job=BatchExportJob(source:input,settings:source,look:nil,lookName:"HDR")
        job.items=[first,second]; job.outputDirectory=directory; job.longEdge=32; job.format = .jpeg
        let journal=BatchJournal(directory:directory.appendingPathComponent("job"))
        let model=BatchExportModel(job:job,journal:journal,hdrPreparation:preparer)
        model.inspect(first)
        let previewDeadline=Date().addingTimeInterval(30)
        while model.previewing && Date()<previewDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
        check(model.preview?.hdr != nil,"batch effect inspection lost the HDR float presentation")
        let frozenHeadroom=model.preview!.hdr!.statistics.headroom
        model.closePreview(); check(model.preview==nil,"closed batch preview retained its float owner")
        model.start()
        let deadline=Date().addingTimeInterval(30)
        while model.running && Date()<deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
        check(!model.running && model.error==nil && model.job.succeededCount==2,"mixed batch did not complete: \(model.error ?? "timeout")")
        check(model.job.mode == .perTargetFrozen && model.job.version==3,"mixed batch did not persist per-target snapshots")
        check(model.job.items[0].frozen?.settings.isHDREditing==true && model.job.items[1].frozen?.settings.isHDREditing==false,"frozen modes leaked between targets")
        var external=source; external.hdr?.mode = .sdr; external.exposure=3
        try store.save(input,state:PhotoEditState(settings:external,filmID:""))
        model.inspect(model.job.items[0])
        let frozenPreviewDeadline=Date().addingTimeInterval(30)
        while model.previewing && Date()<frozenPreviewDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
        check(model.preview?.hdr?.statistics.headroom==frozenHeadroom,"frozen batch inspection reread later editing records")
        model.closePreview()
        for item in model.job.items { let info=try HDRSourceInfo.probe(item.output!); check(info==nil,"SDR batch output carried a gain map") }
        print("PASS Mac mixed HDR/legacy SDR preparation, frozen modes, WB rejection, record isolation and SDR batch output")
    }
}
