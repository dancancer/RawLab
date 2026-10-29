import Foundation
import UIKit

@main enum HDRBatchTests {
    static func check(_ value: @autoclosure () -> Bool,_ message: String) { if !value() { fatalError(message) } }
    static func main() throws {
        setbuf(stdout,nil)
        let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let input=URL(fileURLWithPath:CommandLine.arguments[2])
        let store=try EditPersistence(directory:root.appendingPathComponent("edits"))
        let editor=RawEditorViewModel(editPersistence:store)
        let legacy=root.appendingPathComponent("legacy.jpg")
        try FileManager.default.copyItem(at:input,to:legacy)
        let aID=PhotoIdentity(resourceIdentifier:"new-hdr"),bID=PhotoIdentity(resourceIdentifier:"legacy-sdr")
        var old=RawSettings.default; old.exposure = -0.5
        try store.save(bID,state:PhotoEditState(settings:old))
        let previous=try store.versionedState(for:bID)
        var settings=RawSettings.default; settings.hdr=HDRSettings(); settings.hdr?.exposure=1
        let source=BatchSourceSnapshot(identity:aID,sourceFile:.externallyManaged(input),displayName:input.lastPathComponent,
            sourceKind:.raster,settings:settings)
        let a=BatchTarget(identity:aID,sourceURL:input,displayName:"new-hdr.jpg",sourceKind:.raster)
        let b=BatchTarget(identity:bID,sourceURL:legacy,displayName:"legacy.jpg",sourceKind:.raster)
        let preparation=IOSHDRBatchPreparation(source:source,editor:editor)
        let first=try preparation.prepare(a,ordinal:0,format:.jpeg,longEdge:32)
        let second=try preparation.prepare(b,ordinal:1,format:.jpeg,longEdge:32)
        check(first.settings.isHDREditing && first.settings.hdr?.exposure==1,"new HDR target missing HDR defaults")
        check(!second.settings.isHDREditing && second.settings.hdr==nil && second.settings.exposure==1,"legacy SDR target inherited HDR mode")
        let unchanged=try store.versionedState(for:bID)
        check(unchanged==previous,"preparation wrote target editing records")
        var incompatibleSettings=settings; incompatibleSettings.hdr?.temperature=8000
        let incompatible=BatchSourceSnapshot(identity:aID,sourceFile:.externallyManaged(input),displayName:input.lastPathComponent,
            sourceKind:.raster,settings:incompatibleSettings)
        do {
            _ = try IOSHDRBatchPreparation(source:incompatible,editor:editor).prepare(b,ordinal:1,format:.jpeg,longEdge:32)
            fatalError("relative HDR white balance entered an SDR target")
        } catch AdjustmentTransferError.incompatible {}
        let journal=try BatchJournalStore(directory:root.appendingPathComponent("journal"))
        let invalidFormat=BatchExportModel(job:BatchExportJob(source:source,targets:[a,b],outputFormat:.hdrJPEG,longEdge:32),
            journalStore:journal,jpegWriter:{ _,_,_,_ in fatalError("incompatible format reached output") },editor:editor)
        invalidFormat.start()
        let rejectedDeadline=Date().addingTimeInterval(30)
        while invalidFormat.isRunning && Date()<rejectedDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
        check(invalidFormat.validationMessage != nil && invalidFormat.canChangeTargets,
            "format preflight failure locked the draft instead of letting the user choose SDR JPEG")
        let job=BatchExportJob(source:source,targets:[a,b],outputFormat:.jpeg,longEdge:32)
        let output=root.appendingPathComponent("outputs"); try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var outputs=[String]()
        let model=BatchExportModel(job:job,journalStore:journal,jpegWriter:{ data,name,target,checkpoint in
            let url=output.appendingPathComponent(name)
            try data.write(to:url)
            let info=try HDRSourceInfo.probe(url)
            check(info==nil,"explicit SDR batch output retained gain map")
            try checkpoint("test-"+target.id); outputs.append(target.id)
        },editor:editor)
        func inspect(_ target: BatchTarget) throws -> BatchExportModel.Preview {
            let done=DispatchSemaphore(value:0)
            var result: Result<BatchExportModel.Preview,Error>?
            Task.detached {
                do { result = .success(try await model.preview(target:target)) }
                catch { result = .failure(error) }
                done.signal()
            }
            while done.wait(timeout:.now()) != .success { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
            return try result!.get()
        }
        let beforePreview=try inspect(a)
        check(beforePreview.hdr != nil,"HDR batch effect inspection used a legacy SDR buffer")
        let legacyPreview=try inspect(b)
        check(legacyPreview.hdr==nil,"legacy SDR target inspection inherited source HDR mode")
        model.start()
        let deadline=Date().addingTimeInterval(45)
        while model.isRunning && Date()<deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
        check(!model.isRunning && model.validationMessage==nil && model.completedCount==2,"mixed iOS batch failed: \(model.validationMessage ?? "timeout")")
        check(outputs.count==2 && model.job.settingsMode == .perTargetFrozen && model.job.version==2,"batch did not freeze each target")
        check(model.job.targets[0].frozen?.settings.isHDREditing==true && model.job.targets[1].frozen?.settings.isHDREditing==false,
            "frozen editing mode leaked between targets")
        let reopened=try journal.load(id:model.job.id)
        check(reopened?.targets[1].frozen?.settings.hdr==nil,"journal recovery changed legacy editing mode")
        let after=try store.versionedState(for:bID)
        check(after==previous,"batch output wrote target editing records")
        var external=RawSettings.default; external.exposure=3
        try store.save(aID,state:PhotoEditState(settings:external))
        let frozenPreview=try inspect(model.job.targets[0])
        check(frozenPreview.hdr != nil && frozenPreview.hdr?.statistics.headroom==beforePreview.hdr?.statistics.headroom,
            "frozen batch inspection reread a later SDR editing record")
        let rejected=BatchExportModel(job:BatchExportJob(source:incompatible,targets:[]),journalStore:journal,editor:editor)
        let copyRoot=try BatchInputStore.directory(for:rejected.job.id,root:journal.directory)
        let before=try FileManager.default.contentsOfDirectory(at:copyRoot,includingPropertiesForKeys:nil)
        let done=DispatchSemaphore(value:0)
        var rejectedAsExpected=false
        Task.detached {
            do { _ = try await rejected.prepareTarget(.raster(legacy),identity:bID,jobID:rejected.job.id,journalStore:journal) }
            catch AdjustmentTransferError.incompatible { rejectedAsExpected=true }
            catch { print("Unexpected preparation error: \(error)") }
            done.signal()
        }
        while done.wait(timeout:.now()) != .success { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
        check(rejectedAsExpected,"incompatible copied target accepted")
        let remaining=try FileManager.default.contentsOfDirectory(at:copyRoot,includingPropertiesForKeys:nil)
        check(before==remaining,"failed target preparation leaked its new private input copy")
        print("PASS iOS mixed HDR/SDR batch preparation, frozen modes, WB rejection, record isolation, output and failed-copy cleanup")
    }
}
