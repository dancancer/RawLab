import RawLabKit
import AppKit

extension EditorModel {
    var canUseWBProbe: Bool {
        guard !settings.isHDREditing, let file else { return false }
        if RenderEngine.isRasterInput(file) { return settings.masterRecipeID == nil }
        if RenderEngine.isX3fInput(file) && settings.x3fMode == .normal { return false }
        return settings.asShotWhiteBalance != nil
    }

    var wbProbeActive: Bool {
        wbEyedropperEnabled && canUseWBProbe && adjustmentNavigation.tool == .whiteBalance &&
        adjustmentNavigation.expandedGroup != nil && geometryDraft == nil &&
        pendingGeometryPresentation == nil && !exporting && adjustmentSheet == nil
    }

    func sampleWBProbe(at point: CGPoint) {
        guard wbProbeActive, ParameterValueField.commitPendingInputs(), !busy, !previewOutdated,
              let work = hslAcceptedRequest?.value, work.file == file else {
            wbProbeNotice = .stale
            return
        }
        wbProbeSampling = true
        wbProbeNotice = nil
        let before = settings
        let source = sourceRevision
        let isRaster = RenderEngine.isRasterInput(work.file)
        queue.async { [weak self] in
            guard let self else { return }
            let outcome: Result<RenderEngine.WBProbeSample, Error>
            do {
                if self.engine == nil { self.engine = try RenderEngine() }
                let sample = try self.engine!.sampleWBProbe(work.file, settings: work.settings,
                    lut: work.lut, edge: work.edge, interactive: work.pass == .interactive, point: point)
                outcome = .success(sample)
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                self.wbProbeSampling = false
                guard self.sourceRevision == source, self.settings == before, self.wbProbeActive else {
                    self.wbProbeNotice = .stale
                    return
                }
                switch outcome {
                case .success(let sample):
                    switch sample.availability {
                    case SONY2FUJI_WB_PROBE_AVAILABLE:
                        self.wbProbeNotice = nil
                        self.setInteracting(true)
                        if !isRaster { self.settings.whiteBalanceMode = .custom }
                        else { self.settings.whiteBalanceMode = .asShot }
                        self.settings.temperature = sample.temperature
                        self.settings.tint = sample.tint
                        self.setInteracting(false)
                    case SONY2FUJI_WB_PROBE_OVEREXPOSED:
                        self.wbProbeNotice = .overexposed
                    case SONY2FUJI_WB_PROBE_OUTSIDE:
                        self.wbProbeNotice = .outside
                    default:
                        self.wbProbeNotice = .unavailable
                    }
                case .failure:
                    self.wbProbeNotice = .failed
                }
            }
        }
    }

    func cancelWBProbe() {
        wbProbeNotice = nil
        wbProbeSampling = false
    }

    func rejectWBProbe() {
        wbProbeNotice = .outside
    }
}
