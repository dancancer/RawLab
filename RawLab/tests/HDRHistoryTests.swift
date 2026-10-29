import Foundation
import UIKit

@main enum HDRHistoryTests {
    static func check(_ value: @autoclosure () -> Bool,_ message: String) { if !value() { fatalError(message) } }
    static func main() throws {
        setbuf(stdout,nil)
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let input=root.appendingPathComponent("source.heic"); try Data([1,2,3]).write(to:input)
        let store=try EditPersistence(directory:root.appendingPathComponent("edits"))
        let model=RawEditorViewModel(editPersistence:store)
        let identity=PhotoIdentity(resourceIdentifier:"first-hdr-edit")
        model.sourceFile = .externallyManaged(input); model.sourceIdentity=identity
        model.sourceKind = .raster; model.sourceIsHDR=true; model.hasImage=true
        var settings=RawSettings.default; settings.hdr=HDRSettings()
        model.acceptImportedEditRecord(try store.versionedState(for:identity),settings:settings)
        let absent=try store.versionedState(for:identity)
        try model.copyAdjustments(scope:.custom([.hdrTemperature]),settings:settings)
        let clipboard=model.adjustmentSession?.clipboard
        let history=model.adjustmentSession?.transactions.map(\.id)
        let preset: AdjustmentTransferPayload
        do {
            preset=try model.capturePresetAdjustments(scope:.custom([
                .exposure,.highlights,.shadows,.contrast,.saturation,.hdrTemperature,.hdrTint
            ]),settings:settings)
        } catch {
            print("FAIL fresh HDR preset capture: \(error)")
            throw error
        }
        check(preset.fields.count==7 && preset[.hdrTemperature]?.number==6500 && preset[.hdrTint]?.number==0,
            "new HDR import cannot capture a preset with relative white balance")
        let library=AdjustmentPresetStore(directory:root.appendingPathComponent("presets"))
        _ = try library.create(name:"Fresh HDR",payload:preset)
        let receipt=try store.versionedState(for:identity)
        check(receipt==absent && model.adjustmentSession?.clipboard==clipboard &&
            model.adjustmentSession?.transactions.map(\.id)==history,
            "saving a fresh HDR preset changed its photo, clipboard or history")
        print("PASS fresh HDR preset saves without an edit record or side effects")
        model.batchSelection.append(model.currentAdjustmentPhoto!)
        let target=PhotoIdentity(resourceIdentifier:"hdr-sync-target")
        model.batchSelection.append(.init(identity:target,displayName:"HDR target",
            file:.externallyManaged(input),isRaw:false))
        do {
            let sync=try model.captureCollectionSynchronization(scope:.custom([
                .exposure,.highlights,.shadows,.contrast,.saturation,.hdrTemperature,.hdrTint
            ]),settings:settings)
            check(sync.photos.map(\.id)==[target.key] && sync.payload.fields.count==7,
                "fresh HDR synchronization cannot freeze the common HDR fields")
            let relative=try model.captureCollectionSynchronization(scope:.custom([.hdrTemperature,.hdrTint]),settings:settings)
            check(relative.payload[.hdrTemperature]?.number==6500 && relative.payload[.hdrTint]?.number==0,
                "HDR synchronization lost relative white balance")
        } catch {
            print("FAIL fresh HDR synchronization capture: \(error)")
            throw error
        }
        let afterSync=try store.versionedState(for:identity)
        check(afterSync==absent,"HDR synchronization capture modified the source record")
        print("PASS fresh HDR collection synchronization freezes common and relative WB fields")
        check(model.beginAdjustmentInteraction(settings:settings),"first HDR gesture rejected")
        settings.hdr?.exposure=1
        check(model.endAdjustmentInteraction(settings:settings),"first HDR edit did not save")
        _ = model.performAdjustmentHistory(undo:true)
        check(model.adjustmentRestoredSettings?.isHDREditing==true && model.adjustmentRestoredSettings?.hdr?.exposure==0,
            "undo of the first HDR edit restored SDR defaults")
        _ = model.performAdjustmentHistory(undo:false)
        check(model.adjustmentRestoredSettings?.isHDREditing==true && model.adjustmentRestoredSettings?.hdr?.exposure==1,
            "redo lost HDR editing mode")
        try store.reset(identity)
        model.pendingSettings=nil; model.failedDraftSource=nil
        check(model.reloadSavedAdjustments() && model.adjustmentRestoredSettings?.isHDREditing==true,
            "reloading an absent HDR record changed the source default mode")
        print("PASS iOS first HDR edit undo/redo and absent-record reload preserve HDR defaults")
    }
}
