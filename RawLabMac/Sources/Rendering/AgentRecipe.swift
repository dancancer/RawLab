import Foundation

extension RenderEngine {
    // 复用实际渲染映射，固化配方强度和当前照片白平衡，不在 Agent 中再次叠加。
    func agentRecipe(_ url: URL, settings: Adjustments, lut: URL?, output: URL,
                     exportLongEdge: Int? = nil) throws -> Data {
        if let hdr=settings.hdr, hdr.mode == .hdr {
            guard try HDRSourceInfo.probe(url) != nil else {
                throw RenderError.failed(L10n.text("此照片不包含受支持的 HDR 增益图。"))
            }
            guard ExportFormat.forOutput(output) == .jpeg else {
                throw RenderError.failed(L10n.text("HDR Agent 配方仅支持 HDR JPEG 输出。"))
            }
            return try HDRRecipe.document(settings:hdr,input:url,output:output,baseColor:.displayP3,longEdge:exportLongEdge)
        }
        guard try HDRSourceInfo.probe(url)==nil else {
            throw RenderError.failed(L10n.text("HDR 原片的 Agent 配方需要启用 HDR 编辑。"))
        }
        guard !settings.aiDenoiseEnabled else {
            throw RenderError.failed(L10n.text("Agent 配方不支持 AI 降噪，请先关闭 AI 降噪。"))
        }
        if let edge = exportLongEdge, !(1...65535).contains(edge) {
            throw RenderError.failed(L10n.text("导出长边必须为 1-65535 像素。"))
        }
        let state = try resolvedSettings(url, settings: settings)
        var request = sony2fuji_request()
        state.apply(to: &request)
        let hsl = state.renderHSLSettings
        let fx = state.photoEffectsConfig
        let geometry = state.geometrySettings
        let lens = state.lensSettings
        let wavelet = state.waveletNoiseReduction
        let chroma = wavelet == nil ? (state.chromaNoiseReduction ?? 0) : 0
        let raw = wavelet == nil && chroma == 0 ? state.rawNoiseReduction : 0
        var wb: [String: Any] = ["mode": "camera"]
        let raster = Self.isRasterInput(url)
        if raster { wb = ["mode": "none"] }
        if request.wb_mode == SONY2FUJI_WB_TEMPERATURE {
            wb = ["mode": "temperature", "temperature_kelvin": request.temperature, "tint": request.tint]
        }
        let exposure: String
        switch state.exposureMode {
        case .scene: exposure = "scene"
        case .preview: exposure = "preview"
        case .sensor: exposure = "sensor"
        }
        let format: String
        switch ExportFormat.forOutput(output) {
        case .jpeg, .hdrJPEG: format = "jpeg"
        case .png: format = "png"
        case .renderedDNG: format = "dng"
        }
        let size: [String: Any] = exportLongEdge.map { ["mode": "limit_long_edge", "long_edge": $0] } ?? ["mode": "native"]
        guard state.toneSettings.isValid else { throw RenderError.failed(L10n.text("无效的黑白场或鲜艳度参数")) }
        guard state.curveSettings.isValid else { throw RenderError.failed(L10n.text("无效的曲线参数")) }
        guard state.atmosphereSettings.isValid else { throw RenderError.failed(L10n.text("无效的清晰度或去朦胧参数")) }
        let atmosphereConfig = state.renderAtmosphereSettings.nativeConfig
        let toneConfig = state.renderToneSettings.nativeConfig
        var tone: [String: Any] = ["contrast": min(2, max(0, request.contrast)), "saturation": min(2, max(0, request.saturation)),
            "highlights": min(1, max(-1, request.highlights)), "shadows": min(1, max(-1, request.shadows)), "s_curve": request.tone_curve]
        tone["curve"] = ["mode": state.renderCurveSettings.mode.rawValue, "points": state.renderCurveSettings.points.map { [$0.x, $0.y] }]
        if toneConfig.black_point != 0 { tone["black_point"] = toneConfig.black_point }
        if toneConfig.white_point != 0 { tone["white_point"] = toneConfig.white_point }
        var document: [String: Any] = [
            "schema_version": 5,
            "processing": ["family": state.processing.family, "version": state.processing.version,
                           "quality": state.processing.quality],
            "input": ["path": url.standardizedFileURL.path, "type": raster ? "raster" : "raw"],
            "edits": [
                "exposure": ["mode": exposure, "ev": request.exposure_ev, "brightness": request.brightness],
                "white_balance": wb,
                "look": ["path": lut?.standardizedFileURL.path as Any? ?? NSNull(), "strength": Float(state.strength)],
                "tone": tone,
                "detail": ["sharpening": request.sharpening],
                "hsl": ["hue": hsl.hue.map(Float.init), "saturation": hsl.saturation.map(Float.init), "lightness": hsl.lightness.map(Float.init)],
                "effects": ["vignette_amount": fx.vignette_amount, "vignette_midpoint": fx.vignette_midpoint,
                            "vignette_roundness": fx.vignette_roundness, "vignette_feather": fx.vignette_feather,
                            "vignette_highlights": fx.vignette_highlights, "grain_amount": fx.grain_amount,
                            "grain_size": fx.grain_size, "grain_roughness": fx.grain_roughness,
                            "clarity": atmosphereConfig.clarity, "dehaze": atmosphereConfig.dehaze],
                "denoise": ["raw_level": Int(raw), "chroma_mode": Int(chroma),
                            "wavelet": ["enabled": wavelet?.enabled ?? false, "luma": Float(wavelet?.luma ?? 0),
                                        "chroma": Float(wavelet?.chroma ?? 46), "coarse": Float(wavelet?.coarse ?? 50)]],
                "lens_correction": ["distortion": lens.distortion, "tca": lens.tca, "auto_crop": lens.autoCrop,
                                    "profile_id": lens.coreProfileID.isEmpty ? NSNull() : lens.coreProfileID as Any],
                "geometry": ["crop": ["x": Float(geometry.cropX), "y": Float(geometry.cropY),
                                      "width": Float(geometry.cropWidth), "height": Float(geometry.cropHeight)],
                             "quarter_turns": geometry.quarterTurns, "flip_horizontal": geometry.flipHorizontal,
                             "flip_vertical": geometry.flipVertical, "straighten_degrees": Float(geometry.straightenDegrees),
                             "perspective": ["horizontal": Float(geometry.perspectiveHorizontal), "vertical": Float(geometry.perspectiveVertical)]]
            ],
            "output": ["path": output.standardizedFileURL.path, "format": format, "jpeg_quality": 95, "size": size]
        ]
        if toneConfig.vibrance != 0, var edits = document["edits"] as? [String: Any] {
            edits["color"] = ["vibrance": toneConfig.vibrance]
            document["edits"] = edits
        }
        guard state.gradingSettings.isValid else { throw RenderError.failed(L10n.text("无效的颜色分级参数")) }
        if !state.renderGradingSettings.isDefault, var edits = document["edits"] as? [String: Any] {
            edits["color_grading"] = Dictionary(uniqueKeysWithValues: ColorGradingZone.allCases.map { zone in
                let wheel = state.renderGradingSettings[zone]
                return (zone.rawValue, ["hue": wheel.nativeHue, "saturation": Float(wheel.saturation)])
            })
            document["edits"] = edits
        }
        return try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    }
}
