import Foundation
import UIKit

@main enum HDRBatchTests {
    static func check(_ value: @autoclosure () -> Bool,_ message: String) { if !value() { fatalError(message) } }
    static func main() throws {
        setbuf(stdout,nil)
        let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let input=URL(fileURLWithPath:CommandLine.arguments[2])
        let store=try EditPersistence(directory:root.appendingPathComponent("edits"))
        let journal=try BatchJournalStore(directory:root.appendingPathComponent("journal"))
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
        if let path = ProcessInfo.processInfo.environment["RAWLAB_TEST_PRORAW"] {
            let raw = URL(fileURLWithPath: path)
            let info = try HDRSourceInfo.probeRAW(raw)
            check(info?.proRAW != nil, "ProRAW fixture was not recognized")
            let rawID = PhotoIdentity(resourceIdentifier: "proraw")
            let target = BatchTarget(identity: rawID, sourceURL: raw, displayName: raw.lastPathComponent, sourceKind: .raw)
            let fresh = try preparation.prepare(target, ordinal: 2, format: .jpeg, longEdge: nil)
            check(!fresh.settings.isHDREditing && fresh.settings.exposure == 1,
                  "fresh ProRAW batch target was silently upgraded to HDR")
            var saved = RawSettings.default; saved.exposure = -2; saved.hdr = HDRSettings()
            saved.proRAWDecodeVersion = ProRAWSource.decodeVersion + 1
            try store.save(rawID, state: PhotoEditState(settings: saved))
            do {
                _ = try preparation.prepare(target, ordinal: 2, format: .hdrJPEG, longEdge: nil)
                fatalError("Incompatible ProRAW version passed HDR preflight")
            } catch HDRSettings.ModeError.invalidSettings {}
            let recovered = BatchExportModel(job: BatchExportJob(source: source, targets: [target]), journalStore: journal)
            do {
                _ = try recovered.render(target: target, settings: saved, look: nil, longEdge: 512, format: .hdrJPEG)
                fatalError("Incompatible frozen ProRAW settings reached JPEG export")
            } catch HDRSettings.ModeError.invalidSettings {}
            saved.hdr?.mode = .sdr
            try store.save(rawID, state: PhotoEditState(settings: saved))
            let sdr = try preparation.prepare(target, ordinal: 2, format: .jpeg, longEdge: nil)
            check(!sdr.settings.isHDREditing && sdr.settings.proRAWDecodeVersion == saved.proRAWDecodeVersion,
                  "ProRAW preflight rejected or rewrote the dormant decoder version in SDR mode")
            saved.hdr?.mode = .hdr
            saved.proRAWDecodeVersion = ProRAWSource.decodeVersion
            try store.save(rawID, state: PhotoEditState(settings: saved))
            let beforeRaw = try store.versionedState(for: rawID)
            let hdr = try preparation.prepare(target, ordinal: 2, format: .hdrJPEG, longEdge: nil)
            check(hdr.settings.isHDREditing && hdr.settings.hdr?.exposure == 1 && hdr.settings.exposure == -2,
                  "saved ProRAW HDR batch target lost its mode or dormant SDR state")
            let afterRaw = try store.versionedState(for: rawID)
            check(afterRaw == beforeRaw, "ProRAW batch preparation wrote target records")
            print("PASS ProRAW batch capability, frozen target modes and record isolation")
        }
        let camera = root.appendingPathComponent("camera.dng")
        let cameraFixture = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RAWLAB_TEST_CAMERA_RAW"]!)
        try FileManager.default.copyItem(at: cameraFixture, to: camera)
        let cameraID = PhotoIdentity(resourceIdentifier: "camera")
        let cameraTarget = BatchTarget(identity: cameraID, sourceURL: camera, displayName: "camera.dng", sourceKind: .raw)
        let freshCamera = try preparation.prepare(cameraTarget, ordinal: 2, format: .jpeg, longEdge: 64)
        check(!freshCamera.settings.isHDREditing && freshCamera.settings.exposure == 1,
              "New camera RAW should remain in SDR editing")
        var cameraEdit = RawSettings.default; cameraEdit.exposure = -2; cameraEdit.hdr = HDRSettings()
        cameraEdit.hdr?.renditionSettings.sdrExposureEV = -0.75
        cameraEdit.proRAWDecodeVersion = ProRAWSource.decodeVersion
        try store.save(cameraID, state: PhotoEditState(settings: cameraEdit))
        do {
            _ = try preparation.prepare(cameraTarget, ordinal: 2, format: .hdrJPEG, longEdge: 64)
            fatalError("Camera RAW accepted a ProRAW decode version")
        } catch HDRSettings.ModeError.invalidSettings {}
        cameraEdit.proRAWDecodeVersion = nil
        try store.save(cameraID, state: PhotoEditState(settings: cameraEdit))
        let cameraFrozen = try preparation.prepare(cameraTarget, ordinal: 2, format: .hdrJPEG, longEdge: 64)
        check(cameraFrozen.settings.isHDREditing && cameraFrozen.settings.hdr?.exposure == 1 &&
              cameraFrozen.settings.exposure == -2, "Camera RAW batch lost its saved mode or dormant SDR")
        let collection = IOSBatchSelection()
        collection.append(.init(identity: cameraID, displayName: "camera.dng", file: .externallyManaged(camera), isRaw: true))
        collection.append(.init(identity: bID, displayName: "legacy.jpg", file: .externallyManaged(legacy), isRaw: false))
        collection.append(.init(identity: aID, displayName: "new-hdr.jpg", file: .externallyManaged(input), isRaw: false))
        if let path = ProcessInfo.processInfo.environment["RAWLAB_TEST_PRORAW"] {
            let raw = URL(fileURLWithPath: path)
            collection.append(.init(identity: PhotoIdentity(resourceIdentifier: "proraw"), displayName: raw.lastPathComponent,
                file: .externallyManaged(raw), isRaw: true))
        }
        func cameraReview(_ format: BatchOutputFormat) -> IOSCollectionExportReview {
            collection.exportInput.prepareExport(store: store, skipping: [], format: format, longEdge: 64,
                probeHDR: { try HDRSourceInfo.probe($0) != nil }, validateActive: { _ in }, resolveLook: { _ in (nil, nil) },
                validateHDRSource: { try HDRSourceInfo.validateEditingSource($0, proRAWDecodeVersion: $1) })
        }
        let hdrCameraReview = cameraReview(.hdrJPEG)
        check(!hdrCameraReview.ready && hdrCameraReview.rows.enumerated().filter { $0.element.error != nil }.map(\.offset) == [1],
              "Mixed HDR JPEG collection failed to identify the SDR row")
        let cameraJob = try collection.freeze(cameraReview(.jpeg), store: store, journal: journal, validateActive: { _ in })
        check(cameraJob.targets[0].frozen?.settings == cameraEdit && cameraJob.targets[1].frozen?.settings == old &&
              cameraJob.targets.dropFirst(2).allSatisfy { $0.frozen?.settings.isHDREditing == true },
              "Collection freeze did not keep each photo's own adjustments")
        var targetDevelopment = HDRCameraDevelopmentSettings()
        targetDevelopment.selectWhiteBalance(.temperature)
        targetDevelopment.temperature = 5200; targetDevelopment.tint = 17
        targetDevelopment.exposureReference = .sensor
        targetDevelopment.lensDistortion = true; targetDevelopment.lensTCA = true
        targetDevelopment.lensAutoCrop = false; targetDevelopment.lensProfile = "target lens profile"
        targetDevelopment.cameraProfile = HDRCameraProfile(
            sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            name: "target camera profile")
        do {
            let original = try store.versionedState(for: cameraID).state!
            defer { try? store.save(cameraID, state: original) }
            var targetSettings = original.settings
            targetSettings.hdr?.cameraDevelopmentSettings = targetDevelopment
            let target = PhotoEditState(settings: targetSettings)
            try store.save(cameraID, state: target)
            let prepared = try preparation.prepare(cameraTarget, ordinal: 2, format: .jpeg, longEdge: 64)
            check(targetDevelopment != settings.hdr!.cameraDevelopmentSettings &&
                  prepared.settings.hdr?.cameraDevelopmentSettings == targetDevelopment,
                  "iOS HDR batch preparation copied source camera development over the target")

            let cameraOnly = IOSBatchSelection()
            let cameraPhoto = IOSAdjustmentPhoto(identity: cameraID, displayName: "camera.dng",
                file: .externallyManaged(camera), isRaw: true)
            cameraOnly.append(cameraPhoto)
            let row = IOSCollectionExportReview.Row(photo: IOSCollectionPhoto(cameraPhoto),
                record: try store.versionedState(for: cameraID), settings: target.settings,
                look: nil, lookSHA256: nil, lookName: "HDR", error: nil)
            let review = IOSCollectionExportReview(selection: [cameraID.key], rows: [row],
                format: .jpeg, longEdge: 64)
            let freezeJournal = try BatchJournalStore(directory: root.appendingPathComponent("camera-profile-freeze"))
            var frozenID: UUID?
            defer { if let id = frozenID { try? freezeJournal.discard(id: id) } }
            let frozen = try cameraOnly.freeze(review, store: store, journal: freezeJournal, validateActive: { _ in })
            frozenID = frozen.id
            check(frozen.targets[0].frozen?.settings.hdr?.cameraDevelopmentSettings == targetDevelopment,
                  "iOS collection freeze copied source camera development over the target")
        }
        let savedCamera = try store.versionedState(for: cameraID)
        let cameraRenderer = BatchExportModel(job: cameraJob, journalStore: journal)
        let outputFile = root.appendingPathComponent("camera-export.jpg")
        let cameraJPEG = try cameraRenderer.render(target: cameraTarget, settings: cameraEdit, look: nil, longEdge: 64, format: .hdrJPEG)
        try cameraJPEG.write(to: outputFile)
        let cameraOutput = try HDRSourceInfo.probe(outputFile)
        let afterCamera = try store.versionedState(for: cameraID)
        check(cameraOutput != nil && afterCamera == savedCamera, "Camera RAW gain-map readback or record isolation failed")
        print("PASS iOS camera RAW HDR batch preflight, collection freeze and v4 export")
        if HDRImage.heifExportAvailable {
            let frozen = try preparation.prepare(cameraTarget, ordinal: 0, format: .hdrHEIF, longEdge: 64)
            let heif = try cameraRenderer.render(target: cameraTarget, settings: frozen.settings, look: nil,
                                                longEdge: 64, format: frozen.outputFormat)
            let output = root.appendingPathComponent("camera-export.\(frozen.outputFormat.suffix)")
            try heif.write(to: output)
            let info = try HDRSourceInfo.probe(output)
            check(output.pathExtension == "heic" && info?.native.protocol == UInt32(SONY2FUJI_HDR_PROTOCOL_ISO)
                  && info?.native.width == 64, "iOS batch HEIF lost its suffix, size or ISO gain map")
            print("PASS iOS camera RAW HDR HEIF batch rendition")
        } else {
            do {
                _ = try preparation.prepare(cameraTarget, ordinal: 0, format: .hdrHEIF, longEdge: 64)
                fatalError("An unsupported runtime accepted an HDR HEIF batch")
            } catch BatchExportError.target { }
            print("PASS iOS batch preflight rejects unavailable HDR HEIF encoder")
        }

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
