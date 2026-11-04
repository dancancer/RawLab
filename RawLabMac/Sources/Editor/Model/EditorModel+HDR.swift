import Foundation

extension EditorModel {
    func referenceSource(_ url: URL) -> MacReferenceSource {
        MacReferenceSource(url,raster:RenderEngine.isRasterInput(url),
            hdrFingerprint:(try? HDRSourceInfo.probe(url))?.fingerprint)
    }
    func setHDREditing(_ enabled: Bool) {
        guard sourceIsHDR || sourceSupportsCameraHDR, enabled != settings.isHDREditing, canExport, let file else { return }
        guard saveEdits() else { return }
        do {
            var candidate=try settings.withHDRMode(enabled,sourceIsHDR:sourceIsHDR,
                hasLook:!selectedFilmID.isEmpty || settings.masterRecipeID != nil,
                cameraRAW:sourceSupportsCameraHDR)
            if enabled, sourceSupportsCameraHDR, try HDRSourceInfo.probeRAW(file)?.proRAW != nil {
                candidate.proRAWDecodeVersion = ProRAWSource.decodeVersion
            }
            let snapshot=editState(settings:candidate)
            if enabled && sourceSupportsCameraHDR {
                preflightCameraHDR(file, snapshot: snapshot)
            } else {
                activateHDRMode(snapshot)
            }
        } catch HDRSettings.ModeError.conflicts {
            error=L10n.text("当前 SDR 调整包含 HDR 暂不支持的工具。请先重置这些工具，再启用 HDR。")
        } catch { self.error=error.localizedDescription }
    }

    private func preflightCameraHDR(_ url: URL, snapshot: PhotoEditState) {
        let opening = pendingOpenID
        let previous = editState(settings: settings)
        let edge = renderPreviewLongEdge
        importing = true
        queue.async { [weak self] in
            let validation = Result {
                let engine = try RenderEngine()
                _ = try engine.render(url, settings: snapshot.settings, lut: nil, edge: edge)
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
