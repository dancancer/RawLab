import SwiftUI
import UniformTypeIdentifiers

struct HDRMonitoringControls: View {
    @ObservedObject var state: HDRDisplayState
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            Picker(L10n.text("预览方式"),selection:$state.mode) {
                Text(L10n.text("自动 HDR")).tag(HDRPreviewMode.automatic)
                Text(L10n.text("SDR 兼容预览")).tag(HDRPreviewMode.sdr)
            }.pickerStyle(.segmented).accessibilityIdentifier("hdr.previewMode")
            Toggle(L10n.text("HDR 假色"),isOn:$state.falseColor).accessibilityIdentifier("hdr.falseColor")
            Text(state.displayFailed ? L10n.text("HDR 显示不可用，当前显示 SDR。") :
                L10n.format("屏幕容量 %@ EV",String(format:"%.2f",log2(max(1,state.headroom)))))
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("hdr.displayStatus")
            if state.displayFailed {
                Button(L10n.text("重试")) { state.retry &+= 1 }.accessibilityIdentifier("hdr.retry")
            }
            if !state.displayFailed && (state.mode == .sdr || state.headroom <= 1) {
                Text(L10n.text("当前显示 SDR 兼容预览。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if state.falseColor {
                Text(L10n.text("假色：蓝色为暗部，琥珀色高于参考白，粉色超出屏幕容量。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            Text(L10n.text("预览方式不会改变编辑或导出。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
    }
}

struct HDRRenditionControls: View {
    @Binding var settings: HDRRenditionSettings
    let onEditingChanged: (Bool) -> Void
    let onCancelled: () -> Void
    @State private var editing = false

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                slider("HDR 亮度上限", value: $settings.peakLimitEV, range: 0...6, step: 0.1, id: "peakLimit",
                       unit: "EV", unlimitedAtZero: true)
                slider("SDR 底图曝光", value: $settings.sdrExposureEV, range: -4...4, step: 0.1, id: "sdrExposure", unit: "EV")
                slider("SDR 底图对比度", value: $settings.sdrContrast, range: -100...100, step: 1, id: "sdrContrast", unit: "%")
                slider("SDR 底图饱和度", value: $settings.sdrSaturation, range: -100...100, step: 1, id: "sdrSaturation", unit: "%")
            }.padding(.top, 6)
                .onDisappear { if editing { editing = false; onCancelled() } }
        } label: {
            Text(L10n.text("HDR 输出与 SDR 底图")).accessibilityIdentifier("hdr.rendition")
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                        id: String, unit: String, unlimitedAtZero: Bool = false) -> some View {
        let current = value.wrappedValue
        let text = unlimitedAtZero && current == 0 ? L10n.text("不限") :
            String(format: unit == "EV" ? "%+.1f %@" : "%+.0f%@", locale: L10n.locale, current, unit)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(L10n.text(title))
                Spacer()
                Text(text).monospacedDigit()
            }.font(.caption)
            Slider(value: value, in: range, step: step, onEditingChanged: { active in
                editing = active
                onEditingChanged(active)
            })
            .accessibilityLabel(L10n.text(title))
            .accessibilityValue(text)
            .accessibilityIdentifier("hdr.rendition.\(id)")
        }
    }
}

struct HDRLookControls: View {
    @Binding var settings: HDRSettings
    let onEditingChanged: (Bool) -> Void
    let onCancelled: () -> Void
    @State private var choosingFile = false
    @State private var importing = false
    @State private var failed = false
    @State private var editing = false

    private static func bundledSilver(master: Bool, target: HDRSettings) throws -> HDRSettings {
        let look = try HDRLookAssetStore.installHDRSilver()
        if !master {
            var result = target
            result.lookSettings = look
            return result
        }
        guard let recipe = Bundle.main.url(forResource: "HDR Silver Master", withExtension: "json", subdirectory: "BundledLooks/HDR") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let payload = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: Data(contentsOf: recipe))
        guard payload[.hdrLook]?.hdrLookSettings == look else { throw CocoaError(.fileReadCorruptFile) }
        return try HDRAdjustmentTransfer.prepare(payload: payload, target: target)
    }

    private func load(_ apply: @escaping (HDRSettings) throws -> HDRSettings) {
        let before = settings
        importing = true; failed = false
        Task { @MainActor in
            defer { importing = false }
            do {
                let result = try await Task.detached { try apply(before) }.value
                if settings == before { settings = result }
            } catch { failed = true }
        }
    }

    var body: some View {
        let look = settings.lookSettings
        VStack(alignment: .leading, spacing: 6) {
            Text(look.name ?? "HDR LUT").font(.caption.weight(.medium)).lineLimit(2)
                .accessibilityIdentifier("hdr.look.name")
            HStack {
                Button(L10n.text("导入外观…")) { choosingFile = true }
                    .accessibilityIdentifier("hdr.look.import")
                if look.sha256 != nil {
                    Button(L10n.text("中性")) { settings.lookSettings = HDRLookSettings() }
                        .accessibilityIdentifier("hdr.look.clear")
                }
            }
            HStack {
                Button("HDR Silver") { load { try Self.bundledSilver(master: false, target: $0) } }
                    .accessibilityIdentifier("hdr.look.silver")
                Button("HDR Silver Master") { load { try Self.bundledSilver(master: true, target: $0) } }
                    .accessibilityIdentifier("hdr.look.silver-master")
            }
            if look.sha256 != nil {
                let percent = String(format: "%.0f%%", locale: L10n.locale, look.strength * 100)
                Text(L10n.text("外观强度") + " " + percent).font(.caption).monospacedDigit()
                Slider(value: $settings.lookSettings.strength, in: 0...2, step: 0.01, onEditingChanged: { active in
                    editing = active; onEditingChanged(active)
                }).accessibilityLabel(L10n.text("外观强度")).accessibilityValue(percent)
                    .accessibilityIdentifier("hdr.look.strength")
            }
            if failed {
                Text(L10n.text("无法读取外观文件。")).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("hdr.look.error")
            }
        }.disabled(importing)
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data]) { result in
                guard let url = try? result.get() else { return }
                load { target in
                    var result = target
                    result.lookSettings = try HDRLookAssetStore.install(url)
                    return result
                }
            }
            .onDisappear { if editing { editing = false; onCancelled() } }
    }
}

struct HDRCameraDevelopmentControls: View {
    let settings: HDRCameraDevelopmentSettings
    let supportsBayerDevelopment: Bool
    let apply: (HDRCameraDevelopmentSettings) -> Void
    @State private var draft: HDRCameraDevelopmentSettings
    @State private var choosingProfile = false
    @State private var importingProfile = false
    @State private var profileError: String?

    init(settings: HDRCameraDevelopmentSettings, supportsBayerDevelopment: Bool,
         apply: @escaping (HDRCameraDevelopmentSettings) -> Void) {
        self.settings = settings
        self.supportsBayerDevelopment = supportsBayerDevelopment
        self.apply = apply
        _draft = State(initialValue: settings)
    }

    var body: some View {
        DisclosureGroup("HDR RAW") {
            profileControls
            Picker(L10n.text("白平衡模式"), selection: $draft.whiteBalance) {
                Text(L10n.text("相机白平衡（按目标照片）")).tag(HDRCameraDevelopmentSettings.WhiteBalance.asShot)
                Text(L10n.text("自定义")).tag(HDRCameraDevelopmentSettings.WhiteBalance.temperature)
            }
            .accessibilityIdentifier("hdr.camera.wb")
            .onChange(of: draft.whiteBalance) { _, mode in
                draft.temperature = mode == .asShot ? 0 : 6500
                draft.tint = 0
            }
            if draft.whiteBalance == .temperature {
                cameraSlider("色温", value: $draft.temperature, range: 2000...50000, step: 50, unit: " K", id: "temperature")
                cameraSlider("色调", value: $draft.tint, range: -150...150, step: 1, unit: "", id: "tint")
            }
            Picker(L10n.text("曝光基准"), selection: $draft.exposureReference) {
                Text(L10n.text("场景")).tag(HDRCameraDevelopmentSettings.ExposureReference.metadata)
                Text(L10n.text("传感器基准")).tag(HDRCameraDevelopmentSettings.ExposureReference.sensor)
            }.accessibilityIdentifier("hdr.camera.exposure")
            if supportsBayerDevelopment {
                Picker(L10n.text("RAW 降噪"), selection: $draft.fbddLevel) {
                    Text(L10n.text("关闭")).tag(0)
                    Text("FBDD 1").tag(1)
                    Text("FBDD 2").tag(2)
                }.accessibilityIdentifier("hdr.camera.fbdd")
            }
            Toggle(L10n.text("畸变校正"), isOn: $draft.lensDistortion).accessibilityIdentifier("hdr.camera.distortion")
            Toggle(L10n.text("横向色差"), isOn: $draft.lensTCA).accessibilityIdentifier("hdr.camera.tca")
            Toggle(L10n.text("自动裁切"), isOn: $draft.lensAutoCrop).disabled(!draft.lensActive)
            HStack {
                Button(L10n.text("重置")) { draft = HDRCameraDevelopmentSettings() }.disabled(draft.isDefault)
                Button(L10n.text("应用")) {
                    if !draft.lensActive { draft.lensProfile = nil }
                    apply(draft)
                }.disabled(draft == settings).accessibilityIdentifier("hdr.camera.apply")
            }.buttonStyle(.borderless)
        }.disabled(importingProfile)
            .onChange(of: settings) { _, current in draft = current }
            .fileImporter(isPresented: $choosingProfile, allowedContentTypes: ["dcp", "rlook"].map {
                UTType(filenameExtension: $0, conformingTo: .data) ?? .data
            }) { result in
                guard let url = try? result.get() else { return }
                importingProfile = true
                profileError = nil
                Task { @MainActor in
                    defer { importingProfile = false }
                    do {
                        draft.cameraProfile = try await Task.detached { try HDRCameraProfileAssetStore.install(url) }.value
                    } catch { profileError = error.localizedDescription }
                }
            }
    }

    @ViewBuilder private var profileControls: some View {
        if let profile = draft.cameraProfile {
            LabeledContent(L10n.text("HDR 相机配置"), value: profile.name)
                .accessibilityIdentifier("hdr.camera.profile.name")
        }
        HStack {
            Button(L10n.text("导入相机配置…")) { choosingProfile = true }
                .accessibilityIdentifier("hdr.camera.profile.import")
            if draft.cameraProfile != nil {
                Button(L10n.text("清除相机配置")) { draft.cameraProfile = nil; profileError = nil }
                    .accessibilityIdentifier("hdr.camera.profile.clear")
            }
        }.buttonStyle(.borderless)
        if let profileError { Text(profileError).font(.caption).foregroundStyle(.secondary) }
    }

    private func cameraSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                              step: Double, unit: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.text(title) + " " + String(Int(value.wrappedValue.rounded())) + unit).font(.caption)
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(L10n.text(title)).accessibilityIdentifier("hdr.camera.\(id)")
        }
    }
}

struct HDRLuminanceHistogram: View {
    let statistics: HDRStatistics
    let headroom: Double
    var body: some View {
        Canvas { context,size in
            let maximum=statistics.bins.max() ?? 1
            let width=size.width/256
            for (index,value) in statistics.bins.enumerated() {
                let height=maximum>0 ? size.height*log1p(value)/log1p(maximum) : 0
                context.fill(Path(CGRect(x:Double(index)*width,y:size.height-height,width:width+0.5,height:height)),
                    with:.color(.white.opacity(0.8)))
            }
            for (position,color,dash) in [(0.5,Color.white,[CGFloat]()),
                (HDRStatistics.position(headroom:headroom),Color.yellow,[CGFloat(3),2])] {
                var line=Path(); line.move(to:CGPoint(x:position*size.width,y:0))
                line.addLine(to:CGPoint(x:position*size.width,y:size.height))
                context.stroke(line,with:.color(.black.opacity(0.9)),style:StrokeStyle(lineWidth:3,dash:dash))
                context.stroke(line,with:.color(color),style:StrokeStyle(lineWidth:1,dash:dash))
            }
        }.accessibilityLabel(L10n.text("HDR 亮度直方图"))
    }
}
