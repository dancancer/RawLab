import Foundation

extension EditorModel {
    func referenceSource(_ url: URL) -> MacReferenceSource {
        MacReferenceSource(url,raster:RenderEngine.isRasterInput(url),
            hdrFingerprint:(try? HDRSourceInfo.probe(url))?.fingerprint)
    }
    func setHDREditing(_ enabled: Bool) {
        guard sourceIsHDR,enabled != settings.isHDREditing,canExport else { return }
        guard saveEdits() else { return }
        do {
            let candidate=try settings.withHDRMode(enabled,sourceIsHDR:sourceIsHDR,
                hasLook:!selectedFilmID.isEmpty || settings.masterRecipeID != nil)
            let snapshot=editState(settings:candidate)
            guard commitAdjustment(snapshot) else { return }
            resetAITask(); cancelHSLTarget()
            restoreAdjustmentState(snapshot)
            dirty=false; editRevision=UUID()
            adjustmentNavigation.selectTool(.exposure)
            schedule(forceExact:true)
        } catch HDRSettings.ModeError.conflicts {
            error=L10n.text("当前 SDR 调整包含 HDR 暂不支持的工具。请先重置这些工具，再启用 HDR。")
        } catch { self.error=error.localizedDescription }
    }
}
