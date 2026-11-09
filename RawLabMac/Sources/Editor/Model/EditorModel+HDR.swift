import Foundation

extension EditorModel {
    func referenceSource(_ url: URL) -> MacReferenceSource {
        MacReferenceSource(url,raster:RenderEngine.isRasterInput(url),
            hdrFingerprint:(try? probeHDRSource(url, {}))?.fingerprint)
    }
    func setHDREditing(_ enabled: Bool) {
        guard sourceIsHDR || sourceSupportsCameraHDR, enabled != settings.isHDREditing, canExport, let file else { return }
        do {
            var candidate=try settings.withHDRMode(enabled,sourceIsHDR:sourceIsHDR,
                cameraRAW:sourceSupportsCameraHDR)
            if enabled, sourceSupportsCameraHDR, try HDRSourceInfo.probeRAW(file)?.proRAW != nil {
                candidate.proRAWDecodeVersion = try ProRAWSource.validatedDecodeVersion(settings.proRAWDecodeVersion)
            }
            guard saveEdits() else { return }
            let snapshot=editState(settings:candidate)
            if enabled && sourceSupportsCameraHDR {
                preflightCameraHDR(file, snapshot: snapshot)
            } else {
                activateHDRMode(snapshot)
            }
        } catch { self.error=error.localizedDescription }
    }

    func applyHDRCameraDevelopment(_ development: HDRCameraDevelopmentSettings) {
        guard settings.isHDREditing, sourceIsBayerHDR, canApplyHDRCameraDevelopment, let file, let hdr = settings.hdr,
              development.isValid, development != hdr.cameraDevelopmentSettings,
              saveEdits() else { return }
        var candidate = settings
        candidate.hdr?.cameraDevelopmentSettings = development
        if development.fbddLevel != 0 || development.cameraProfile != nil { candidate.hdrCameraAIEnabled = false }
        preflightCameraHDR(file, snapshot: editState(settings: candidate))
    }

    private func preflightCameraHDR(_ url: URL, snapshot: PhotoEditState) {
        let opening = pendingOpenID
        let previous = editState(settings: settings)
        let edge = renderPreviewLongEdge
        importing = true
        queue.async { [weak self] in
            let validation = Result {
                let engine = try RenderEngine()
                var development = snapshot.settings
                development.hdrCameraAIEnabled = false
                _ = try engine.render(url, settings: development, lut: nil, edge: edge)
            }
            DispatchQueue.main.async {
                guard let self, self.file == url, self.pendingOpenID == opening else { return }
                self.importing = false
                guard self.editState(settings: self.settings) == previous else { return }
                switch validation {
                case .success: self.activateHDRMode(snapshot)
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
    }

    private func activateHDRMode(_ snapshot: PhotoEditState) {
        guard commitAdjustment(snapshot) else { return }
        resetAITask(); cancelHSLTarget()
        restoreAdjustmentState(snapshot)
        dirty = false
        editRevision = UUID()
        adjustmentNavigation.selectTool(.exposure)
        schedule(forceExact: true)
    }
}
