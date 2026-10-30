import Foundation

struct AdjustmentTransferSummary {
    struct Group: Identifiable {
        let id: String
        let fields: [AdjustmentTransferField]
    }

    let payload: AdjustmentTransferPayload
    private let locale: Locale
    private let text: (String) -> String

    init(payload: AdjustmentTransferPayload,
         locale: Locale = L10n.locale,
         text: @escaping (String) -> String = { L10n.text($0) }) {
        self.payload = payload
        self.locale = locale
        self.text = text
    }

    var groups: [Group] {
        ["looks", "light", "color", "effects", "detail", "geometry"].compactMap { group in
            let fields = AdjustmentTransferField.allCases.filter {
                $0.group == group && payload.fields.contains($0)
            }
            return fields.isEmpty ? nil : Group(id: group, fields: fields)
        }
    }

    var count: Int { payload.fields.count }

    var includesGeometry: Bool { payload.fields.contains { $0.group == "geometry" } }

    var recipeNote: String? {
        guard let recipe = payload.source.recipe else { return nil }
        let strength = number(recipe.strength * 100) + "%"
        return format("以下为配方逻辑值；强度为 %@。部分范围会按此强度换算。", strength)
    }

    func valueText(for field: AdjustmentTransferField,
                   lookName: (String, String) -> String?) -> String {
        guard let value = payload[field] else { return "" }

        switch field {
        case .look: return lookText(value, lookName: lookName)
        case .strength: return number((value.number ?? 0) * 100) + "%"
        case .exposure: return number(value.number ?? 0, minimumFractionDigits: 2, signed: true) + " EV"
        case .exposureMode:
            switch value.string {
            case "scene": return text("场景")
            case "preview": return text("预览")
            case "sensor": return text("传感器基准")
            default: return value.string ?? ""
            }
        case .contrast: return percent((value.number ?? 1) - 1, signed: true)
        case .highlights: return percent(-(value.number ?? 0), signed: true)
        case .shadows, .sCurve: return percent(value.number ?? 0, signed: true)
        case .blackPoint, .whitePoint, .vibrance, .clarity, .dehaze:
            return number(value.number ?? 0, signed: true) + "%"
        case .saturation: return percent((value.number ?? 1) - 1, signed: true)
        case .hdrTemperature:
            return number(value.number ?? 0) + " K（" + text("相对白平衡") + "）"
        case .hdrTint:
            return number(value.number ?? 0, signed: true) + "（" + text("相对白平衡") + "）"
        case .whiteBalanceMode: return whiteBalanceModeText(value.string)
        case .temperature: return whiteBalanceValue(value, unit: " K")
        case .tint: return whiteBalanceValue(value, unit: "", signed: true)
        case .curve: return curveText(value)
        case .gradingShadows, .gradingMidtones, .gradingHighlights: return gradingText(value)
        case .vignetteAmount, .vignetteRoundness:
            return number(value.number ?? 0, signed: true)
        case .perspectiveHorizontal, .perspectiveVertical:
            return number((value.number ?? 0) * 100, signed: true)
        case .vignetteMidpoint, .vignetteFeather, .vignetteHighlights,
             .grainAmount, .grainSize, .grainRoughness, .rawDenoise, .postRGBDenoise:
            return number(value.number ?? 0)
        case .chromaDenoise: return chromaDenoiseText(value)
        case .waveletDenoise: return waveletText(value)
        case .sharpening: return percent(value.number ?? 0, signed: false)
        case .cropX, .cropY, .cropWidth, .cropHeight: return number((value.number ?? 0) * 100) + "%"
        case .quarterTurns: return number((value.number ?? 0) * 90) + "°"
        case .flipHorizontal, .flipVertical, .lensDistortion, .lensTCA, .lensAutoCrop:
            return text((value.boolean ?? false) ? "开启" : "停用")
        case .straighten: return number(value.number ?? 0, signed: true) + "°"
        case .lensProfile:
            if value == .null { return text("自动（按目标照片）") }
            if value.string == "__rawlab_manual_selection_required__" { return text("待选择的镜头配置") }
            return value.string ?? ""
        case .hslHueRed, .hslHueOrange, .hslHueYellow, .hslHueGreen,
             .hslHueAqua, .hslHueBlue, .hslHuePurple, .hslHueMagenta,
             .hslSaturationRed, .hslSaturationOrange, .hslSaturationYellow,
             .hslSaturationGreen, .hslSaturationAqua, .hslSaturationBlue,
             .hslSaturationPurple, .hslSaturationMagenta,
             .hslLightnessRed, .hslLightnessOrange, .hslLightnessYellow,
             .hslLightnessGreen, .hslLightnessAqua, .hslLightnessBlue,
             .hslLightnessPurple, .hslLightnessMagenta:
            return number(value.number ?? 0, signed: true)
        }
    }

    private func lookText(_ value: AdjustmentTransferValue,
                          lookName: (String, String) -> String?) -> String {
        guard let object = value.object, let kind = object["kind"]?.string else { return "" }
        guard kind != "neutral" else { return text("中性") }
        guard let id = object["id"]?.string else { return kind }
        let type = lookKind(kind)
        if let name = lookName(kind, id), !name.isEmpty {
            return type + " · " + name
        }
        return type + " · " + id + " · " + text("外观不可用。")
    }

    private func lookKind(_ kind: String) -> String {
        switch kind {
        case "builtin": return text("内置")
        case "managed": return text("已保存")
        case "recipe": return text("配方")
        case "recipe_lut": return text("配方 LUT")
        default: return kind
        }
    }

    private func whiteBalanceModeText(_ mode: String?) -> String {
        switch mode {
        case "camera": return text("相机白平衡（按目标照片）")
        case "temperature": return text("自定义")
        case "none": return text("不适用")
        default: return mode ?? ""
        }
    }

    private func whiteBalanceValue(_ value: AdjustmentTransferValue,
                                   unit: String,
                                   signed: Bool = false) -> String {
        if value == .null {
            return payload[.whiteBalanceMode]?.string == "camera"
                ? text("相机白平衡（按目标照片）")
                : text("不适用")
        }
        guard let value = value.number else { return "" }
        return number(value, signed: signed) + unit
    }

    private func curveText(_ value: AdjustmentTransferValue) -> String {
        guard let curve = value.curve else { return text("无效的曲线参数") }
        guard curve.mode == .custom else { return text("S 曲线") }
        let title = format("多点曲线（%d 个控制点）", curve.points.count)
        let points = curve.points.map {
            number($0.x, minimumFractionDigits: 2) + " → " + number($0.y, minimumFractionDigits: 2)
        }.joined(separator: " · ")
        return title + "：" + points
    }

    private func gradingText(_ value: AdjustmentTransferValue) -> String {
        guard let object = value.object,
              let hue = object["hue"]?.number,
              let saturation = object["saturation"]?.number else {
            return text("无效的颜色分级参数")
        }
        return text("色相") + " " + number(hue) + "° · " +
            text("饱和度") + " " + number(saturation) + "%"
    }

    private func chromaDenoiseText(_ value: AdjustmentTransferValue) -> String {
        if value == .null { return text("默认降噪设置") }
        guard let mode = value.number else { return "" }
        switch Int(mode) {
        case 0: return text("停用")
        case 1: return text("细节优先")
        case 2: return text("去噪优先")
        default: return number(mode)
        }
    }

    private func waveletText(_ value: AdjustmentTransferValue) -> String {
        guard let object = value.object,
              let enabled = object["enabled"]?.boolean,
              let luma = object["luma"]?.number,
              let chroma = object["chroma"]?.number,
              let coarse = object["coarse"]?.number,
              let preset = object["preset"]?.string else {
            return value == .null ? text("默认降噪设置") : text("无效的降噪参数")
        }
        let presetText: String
        switch preset {
        case "detail": presetText = text("细节优先")
        case "clean": presetText = text("去噪优先")
        case "custom": presetText = text("自定义")
        default: presetText = preset
        }
        return text(enabled ? "开启" : "停用") + " · " +
            text("亮度降噪") + " " + number(luma) + " · " +
            text("色彩降噪") + " " + number(chroma) + " · " +
            text("粗色斑抑制") + " " + number(coarse) + " · " + presetText
    }

    private func percent(_ value: Double, signed: Bool) -> String {
        number(value * 100, signed: signed) + "%"
    }

    private func format(_ key: String, _ arguments: CVarArg...) -> String {
        let localized = text(key)
        return String(format: localized, locale: locale, arguments: arguments)
    }

    private func number(_ value: Double,
                        minimumFractionDigits: Int = 0,
                        signed: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.maximumFractionDigits = max(2, minimumFractionDigits)
        formatter.roundingMode = .halfUp
        let threshold = minimumFractionDigits > 0
            ? pow(10, Double(-minimumFractionDigits - 1))
            : 0.0000001
        let normalized = abs(value) < threshold ? 0 : value
        let string = formatter.string(from: NSNumber(value: normalized)) ?? String(normalized)
        return signed && normalized > 0 ? "+" + string : string
    }
}
