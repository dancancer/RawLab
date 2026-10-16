import Foundation

@main
struct MacLensDraftControlsTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        print("PASS: \(message)")
    }

    private static let matched = LensCandidate(id: "gm", maker: "Sony", model: "FE 24–70mm F2.8 GM",
                                               hasDistortion: true, hasTCA: true, isMatch: true)
    private static let partial = LensCandidate(id: "za", maker: "Sony", model: "FE 24–70mm F4 ZA OSS",
                                               hasDistortion: true, hasTCA: false, isMatch: false)
    private static let noCalibration = LensCandidate(id: "none", maker: "Sony", model: "Uncalibrated",
                                                     hasDistortion: false, hasTCA: false, isMatch: false)
    private static let candidates = [matched, partial, noCalibration]

    private static func report(_ state: sony2fuji_lens_state = SONY2FUJI_LENS_OFF,
                               distortion: Bool = false, tca: Bool = false, crop: Float = 1,
                               candidates: [LensCandidate] = candidates) -> LensInfo {
        LensInfo(state: state, detectedLens: "FE 24–70mm F2.8 GM", selectedLens: "FE 24–70mm F2.8 GM",
                 focalLength: 35, appliedDistortion: distortion, appliedTCA: tca, cropScale: crop,
                 candidates: candidates)
    }

    static func main() {
        chooser()
        presentation()
    }

    private static func chooser() {
        var settings = LensCorrectionSettings()
        settings.distortion = true
        settings.tca = true
        settings.autoCrop = false
        let original = settings
        var state = MacLensChooserState(settings: settings, candidates: candidates)
        check(state.selectedID == matched.id, "One automatic catalog match starts locally selected")
        state.select(partial.id, candidates: candidates)
        check(settings == original && state.selectedID == partial.id,
              "Browsing another profile leaves the current draft and saved switches untouched")
        let cancelled = MacLensChooserState(settings: settings, candidates: candidates)
        check(cancelled.selectedID == matched.id && settings == original,
              "Dismissal and reopening discard only the chooser's local candidate")
        let used = state.appliedSettings(to: settings, candidates: candidates)
        check(used?.mode == .manual && used?.profileID == partial.id && used?.distortion == true &&
              used?.tca == true && used?.autoCrop == false && settings == original,
              "Explicit use creates a manual draft while preserving independent correction switches")
        state.select("removed", candidates: candidates)
        check(state.selectedID == partial.id, "Unknown candidate IDs cannot replace a local selection")
        check(state.appliedSettings(to: settings, candidates: [matched]) == nil,
              "A profile removed from the catalog cannot be used")
        state.query = "  sony FE 24–70MM F4  "
        check(state.filtered(candidates) == [partial] && state.usableCandidate(in: candidates) == partial,
              "Search trims whitespace and matches maker, lens model, and case")
        state.query = "not a lens"
        check(state.filtered(candidates).isEmpty && state.usableCandidate(in: candidates) == nil,
              "Search with no rows disables use instead of confirming a hidden selection")
        settings.mode = .manual
        settings.profileID = partial.id
        check(MacLensChooserState(settings: settings, candidates: candidates).selectedID == partial.id,
              "Reopening a manual draft starts with its current candidate")
        let ambiguous = [matched, LensCandidate(id: "other", maker: "Sony", model: "Another match",
                                                hasDistortion: true, hasTCA: false, isMatch: true)]
        check(MacLensChooserState(settings: original, candidates: ambiguous).selectedID == nil,
              "Ambiguous automatic matches require an explicit candidate selection")
        check(MacLensChooserState.capabilityKeys(for: partial) == ["畸变标定", "横向色差标定不可用"] &&
              MacLensChooserState.capabilityKeys(for: noCalibration) == ["畸变标定不可用", "横向色差标定不可用"],
              "Candidate descriptions expose missing calibration independently for each correction")
    }

    private static func presentation() {
        var settings = LensCorrectionSettings()
        let off = MacLensPresentation(settings: settings, info: report(), previewIsCurrent: true)
        check(off.candidate == matched && off.identityStatusKey == "已匹配配置 · 校正尚未开启" &&
              off.correctionStatusKey == "镜头校正已关闭" && off.cropPercent == nil,
              "Automatic identity remains matched while corrections are off")
        check(off.canChangeCorrection(tca: false) && off.canChangeCorrection(tca: true),
              "Available distortion and TCA calibration permit independent activation")
        settings.distortion = true
        settings.tca = true
        let stale = MacLensPresentation(settings: settings,
            info: report(SONY2FUJI_LENS_MATCHED, distortion: true, tca: true, crop: 1.1), previewIsCurrent: false)
        check(stale.correctionStatusKey == "正在预览镜头校正…" && stale.cropPercent == nil &&
              stale.correctionDetailKey(tca: false) == "正在预览镜头校正…",
              "A stale report never confirms the draft's correction or crop amount")
        let rendered = MacLensPresentation(settings: settings,
            info: report(SONY2FUJI_LENS_MATCHED, distortion: true, tca: false, crop: 1.1), previewIsCurrent: true)
        check(rendered.correctionDetailKey(tca: false) == "已应用" &&
              rendered.correctionDetailKey(tca: true) == "横向色差未应用" && rendered.cropPercent == 9,
              "Current render reports actual applied corrections and measured crop separately")
        settings.mode = .manual
        settings.profileID = partial.id
        let partialDraft = MacLensPresentation(settings: settings, info: report(), previewIsCurrent: true)
        check(partialDraft.candidate == partial && partialDraft.identityStatusKey == "手动选择" &&
              partialDraft.correctionDetailKey(tca: true) == "横向色差标定不可用" &&
              partialDraft.canChangeCorrection(tca: true),
              "An unsupported enabled TCA value is retained and can still be switched off")
        settings.tca = false
        let partialOff = MacLensPresentation(settings: settings, info: report(), previewIsCurrent: true)
        check(!partialOff.canChangeCorrection(tca: true) && partialOff.canChangeCorrection(tca: false),
              "Missing TCA calibration disables only its activation")
        settings.profileID = "missing"
        let missing = MacLensPresentation(settings: settings, info: report(), previewIsCurrent: true)
        check(missing.candidate == nil && missing.identityStatusKey == "所选镜头不可用" &&
              !missing.canChangeCorrection(tca: true), "Missing manual profiles are explicit and never replaced by an old render's identity")
        settings = LensCorrectionSettings()
        settings.mode = .manual
        let unselected = MacLensPresentation(settings: settings, info: report(), previewIsCurrent: true)
        check(unselected.identityStatusKey == "未匹配镜头，请手动选择" && !unselected.canChangeCorrection(tca: false),
              "Entering manual mode without a profile asks for selection instead of claiming a missing saved profile")
        settings.mode = .automatic
        settings.distortion = true
        for state in [SONY2FUJI_LENS_NO_DATABASE, SONY2FUJI_LENS_NO_CAMERA,
                      SONY2FUJI_LENS_MISSING_FOCAL_LENGTH, SONY2FUJI_LENS_EMBEDDED_GEOMETRY,
                      SONY2FUJI_LENS_UNSUPPORTED_INPUT] {
            let unsupported = MacLensPresentation(settings: settings, info: report(state), previewIsCurrent: true)
            check(!unsupported.inputAllowsCorrection && !unsupported.canChangeCorrection(tca: true) &&
                  unsupported.canChangeCorrection(tca: false),
                  "Unsupported input state \(state.rawValue) exposes the report and permits disabling retained correction")
        }
        let pendingUnsupported = MacLensPresentation(settings: settings,
            info: report(SONY2FUJI_LENS_UNSUPPORTED_INPUT), previewIsCurrent: false)
        check(pendingUnsupported.inputAllowsCorrection && pendingUnsupported.correctionStatusKey == "正在预览镜头校正…",
              "A stale unsupported report cannot disable a newer draft's available calibration")
        let waiting = MacLensPresentation(settings: settings, info: nil, previewIsCurrent: false)
        check(waiting.identityStatusKey == "镜头信息尚未就绪" && waiting.correctionStatusKey == "正在读取镜头信息…" &&
              !waiting.canChangeCorrection(tca: true), "Missing lens information remains explicit without invented capabilities")
        let invalidCrop = MacLensPresentation(settings: settings,
            info: report(SONY2FUJI_LENS_MATCHED, distortion: true, crop: .infinity), previewIsCurrent: true)
        check(invalidCrop.cropPercent == nil, "Invalid crop scale never creates a displayed percentage")
    }
}
