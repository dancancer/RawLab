import Foundation

// ----------------------------------------------------------------------------
//  批量任务的调整摘要：只读的"名称 · 数值"行
//  名称沿用编辑器里的工具与参数名，每个参数只列一次，数值格式与编辑器相同
// ----------------------------------------------------------------------------
struct BatchSettingRow: Equatable {
    let title: String
    let value: String
}

enum BatchSettingsSummary {
    // 常驻四行：曝光、曝光基准、HSL、白平衡
    static func headline(_ settings: RawSettings) -> [BatchSettingRow] {
        if settings.isHDREditing {
            return [row("HDR 编辑",L10n.text("开启")),
                BatchSettingRow(title:AdjustmentKind.exposure.title,value:AdjustmentKind.exposure.displayValue(settings.hdr!.exposure)),
                row("白平衡",L10n.text("相对白平衡"))]
        }
        return [
            BatchSettingRow(title: AdjustmentKind.exposure.title,
                            value: AdjustmentKind.exposure.displayValue(settings.exposure)),
            row("曝光基准", settings.exposureMode.title),
            BatchSettingRow(title: "HSL", value: L10n.text(settings.hsl.isIdentity ? "未调整" : "已调整")),
            row("白平衡", L10n.text(settings.whiteBalanceMode == .camera ? "拍摄时设置" : "自定义"))
        ]
    }

    // "全部调整"展开后：常驻行之外的工具，加上降噪、暗角、颗粒、镜头的各项参数
    static func details(_ settings: RawSettings) -> [BatchSettingRow] {
        if settings.isHDREditing {
            return [AdjustmentKind.highlights,.shadows,.contrast,.saturation,.temperature,.tint].map {
                BatchSettingRow(title:$0.title,value:$0.displayValue($0.value(from:settings)))
            } + geometry(settings.geometrySettings)
        }
        let scalars: [AdjustmentKind] = [.strength, .highlights, .shadows, .contrast, .toneCurve, .blackPoint, .whitePoint, .saturation, .vibrance, .sharpening, .clarity, .dehaze]
        let tools = scalars.filter { settings.curveSettings.isDefault || $0 != .toneCurve }.map {
            BatchSettingRow(title: $0 == .toneCurve ? L10n.text("S 曲线") : $0.title, value: $0.displayValue($0.value(from: settings)))
        }
        let curve = settings.curveSettings.isDefault ? [] :
            [row("曲线", L10n.format("多点曲线（%d 个控制点）", settings.curveSettings.points.count))] +
            settings.curveSettings.points.enumerated().map { index, point in
                BatchSettingRow(title: L10n.format("控制点 %d", index + 1), value: String(format: "%.2f → %.2f", locale: L10n.locale, point.x, point.y))
            }
        let grading = ColorGradingZone.allCases.map { zone in
            BatchSettingRow(title: L10n.text("颜色分级") + " · " + zone.title,
                value: String(format: "%.1f° · %.1f%%", locale: L10n.locale, settings.gradingSettings[zone].hue, settings.gradingSettings[zone].saturation))
        }
        return tools + curve + grading + hsl(settings.hsl) + geometry(settings.geometry) + whiteBalance(settings) + denoise(settings.denoise)
            + effects.map { row($0.key, effectValue(settings.photoEffects, $0.parameter)) } + lens(settings.lensSettings)
    }

    private static func hsl(_ settings: HSLSettings) -> [BatchSettingRow] {
        (0..<8).flatMap { channel in
            HSLAxis.allCases.map { axis in
                BatchSettingRow(title: "HSL · " + L10n.text(HSLSettings.channelNames[channel]) + " · " + axis.title,
                    value: String(format: "%+.1f", locale: L10n.locale, settings.value(axis, channel: channel)))
            }
        }
    }

    private static func geometry(_ value: GeometrySettings) -> [BatchSettingRow] {
        [row("裁切区域", String(format: "%.2f, %.2f · %.2f × %.2f", locale: L10n.locale,
              value.cropX, value.cropY, value.cropWidth, value.cropHeight)),
         row("旋转", "\(value.quarterTurns * 90)°"), row("水平翻转", onOff(value.flipHorizontal)),
         row("垂直翻转", onOff(value.flipVertical)), row("拉直", String(format: "%.2f°", locale: L10n.locale, value.straightenDegrees)),
         row("水平透视", String(format: "%+.2f", locale: L10n.locale, value.perspectiveHorizontal)),
         row("垂直透视", String(format: "%+.2f", locale: L10n.locale, value.perspectiveVertical))]
    }

    // ------------------------------------------------------------------------
    //  分组
    // ------------------------------------------------------------------------

    // 拍摄时白平衡按每张照片各自取值；配方的色调偏移是固定值，不随照片变化
    private static func whiteBalance(_ settings: RawSettings) -> [BatchSettingRow] {
        let perPhoto = settings.whiteBalanceMode == .camera
        let recipe = settings.masterRecipeID != nil
        return [
            row("色温", perPhoto ? L10n.text("按每张照片") : AdjustmentKind.temperature.displayValue(settings.temperature)),
            row(recipe ? "色调偏移" : "色调",
                perPhoto && !recipe ? L10n.text("按每张照片") : AdjustmentKind.tint.formatted(settings.tint))
        ]
    }

    private static func denoise(_ denoise: RawDenoiseSettings) -> [BatchSettingRow] {
        [
            row("降噪", onOff(denoise.enabled)),
            row("亮度降噪", integer(denoise.luma)),
            row("色彩降噪", integer(denoise.chroma)),
            row("粗色斑抑制", integer(denoise.coarse))
        ]
    }

    private static let effects: [(key: String, parameter: PhotoEffectParameter)] = [
        ("暗角强度", .vignetteAmount), ("暗角中点", .vignetteMidpoint), ("暗角圆度", .vignetteRoundness),
        ("暗角羽化", .vignetteFeather), ("暗角高光保护", .vignetteHighlights),
        ("颗粒强度", .grainAmount), ("颗粒大小", .grainSize), ("颗粒粗糙度", .grainRoughness)
    ]

    // 与编辑器的效果参数同一规则：可正可负的参数非零时带正负号
    private static func effectValue(_ effects: PhotoEffectsSettings, _ parameter: PhotoEffectParameter) -> String {
        let value = effects[keyPath: parameter.keyPath]
        let signed = value != 0 && parameter.range.lowerBound < 0
        return String(format: signed ? "%+.0f" : "%.0f", locale: L10n.locale, value)
    }

    private static func lens(_ lens: LensCorrectionSettings) -> [BatchSettingRow] {
        [
            row("镜头匹配", lens.mode == .automatic ? "\(L10n.text("自动")) · \(L10n.text("按每张照片"))" : L10n.text("手动")),
            row("畸变矫正", onOff(lens.distortion)),
            row("横向色差", onOff(lens.tca)),
            row("自动裁边", onOff(lens.autoCrop))
        ]
    }

    // ------------------------------------------------------------------------
    //  小工具
    // ------------------------------------------------------------------------
    private static func row(_ key: String, _ value: String) -> BatchSettingRow {
        BatchSettingRow(title: L10n.text(key), value: value)
    }

    private static func integer(_ value: Double) -> String { String(format: "%.0f", locale: L10n.locale, value) }

    // 目录里"关闭"是关闭按钮（Close），关着的开关用"停用"（Off）
    private static func onOff(_ on: Bool) -> String { L10n.text(on ? "开启" : "停用") }
}
