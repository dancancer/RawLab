import Foundation
import UIKit

@main enum HDRHistoryTests {
    static func check(_ value: @autoclosure () -> Bool,_ message: String) { if !value() { fatalError(message) } }
    static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let input=root.appendingPathComponent("source.heic"); try Data([1,2,3]).write(to:input)
        let store=try EditPersistence(directory:root.appendingPathComponent("edits"))
        let model=RawEditorViewModel(editPersistence:store)
        let identity=PhotoIdentity(resourceIdentifier:"first-hdr-edit")
        model.sourceFile = .externallyManaged(input); model.sourceIdentity=identity
        model.sourceKind = .raster; model.sourceIsHDR=true; model.hasImage=true
        var settings=RawSettings.default; settings.hdr=HDRSettings()
        model.acceptImportedEditRecord(try store.versionedState(for:identity),settings:settings)
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
