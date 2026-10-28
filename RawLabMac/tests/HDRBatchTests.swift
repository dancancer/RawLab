import AppKit
import Foundation

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
