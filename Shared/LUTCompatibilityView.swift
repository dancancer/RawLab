import SwiftUI
import UniformTypeIdentifiers

struct LUTCompatibilityView: View {
    let fileName: String
    let sourceURL: URL
    let initialPhoto: LUTPreviewSource?
    let originalDraft: LUTCompatibility
    let chooseLibraryPhoto: ((@escaping (LUTPreviewSource) -> Void) -> Void)?
    @State var draft: LUTCompatibility
    let finish: (LUTCompatibility?) -> Void
    @StateObject private var preview = LUTCompatibilityPreviewModel()
    @State private var started = false
    @State private var advanced = false
    @State private var showAll = false
    @State private var referenceExpanded = false
    @State private var pickingPhoto = false
    @State private var pickingReference = false
    @State private var conditions = LUTReferenceConditions()

    init(fileName: String, sourceURL: URL, draft: LUTCompatibility, initialPhoto: LUTPreviewSource? = nil,
         chooseLibraryPhoto: ((@escaping (LUTPreviewSource) -> Void) -> Void)? = nil,
         finish: @escaping (LUTCompatibility?) -> Void) {
        self.fileName = fileName; self.sourceURL = sourceURL; self.initialPhoto = initialPhoto
        originalDraft = draft; _draft = State(initialValue: draft); self.finish = finish
        self.chooseLibraryPhoto = chooseLibraryPhoto
    }
    private var candidateList: [LUTCompatibilityCandidate] {
        (originalDraft.candidates ?? []).filter { originalDraft.applying($0, displayInput: preview.displayInput) != nil }
    }
    private var canConfirm: Bool { draft.canImport && (preview.sourceName == nil || preview.frame(for: draft) != nil) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label(L10n.text("兼容导入"), systemImage: "exclamationmark.triangle").font(.headline)
                    Text(fileName).font(.subheadline).textSelection(.enabled)
                    Text(L10n.text("先比较候选效果，再选择导入。候选包含推测，不能证明已还原作者效果。"))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    sourceControls
                    if draft.fixedContract { Text(L10n.text("文件已有完整颜色参数，仅缺少参考依据；这些参数将原样保留。")) .font(.caption).foregroundStyle(.secondary) }
                    if let notice = preview.notice { Text(notice).foregroundStyle(.red).font(.callout) }
                    candidates
                    if let candidate = candidateList.first(where: { originalDraft.applying($0, displayInput: preview.displayInput)?.contract == draft.contract }),
                       !candidate.assumptionsName(baseRendering: draft.contract.baseRendering).isEmpty {
                        Text(candidate.assumptionsName(baseRendering: draft.contract.baseRendering)).font(.caption).foregroundStyle(.secondary)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            imagePane(preview.reference ?? preview.baseline, title: L10n.text(preview.reference == nil ? "未应用 LUT" : "参考图")).frame(minWidth: 240)
                            imagePane(preview.frame(for: draft), title: L10n.text("所选方案")).frame(minWidth: 240)
                        }
                        VStack(spacing: 12) {
                            imagePane(preview.reference ?? preview.baseline, title: L10n.text(preview.reference == nil ? "未应用 LUT" : "参考图"))
                            imagePane(preview.frame(for: draft), title: L10n.text("所选方案"))
                        }
                    }
                    if let failure = preview.failures[LUTCompatibilityPreviewModel.key(draft)] { Text(failure).font(.callout).foregroundStyle(.red) }
                    referenceControls
                    DisclosureGroup(L10n.text("高级颜色设置"), isExpanded: $advanced) {
                        advancedFields.padding(.top, 12)
                    }.accessibilityIdentifier("look.compatibility.advanced")
                    if draft.contract.baseRendering == "rawlab-neutral-v1" {
                        Text(L10n.text("使用 RawLab 中性显影作为基础，不代表还原了相机的标准风格。")) .font(.callout).foregroundStyle(.secondary)
                    } else if draft.contract.baseRendering == "source-display" {
                        Text(L10n.text("仅用于已显影且基础风格匹配的照片，不能直接用于 RAW。")) .font(.callout).foregroundStyle(.secondary)
                    }
                    if draft.extremeValues { Toggle(L10n.text("文件含极端数值，我理解可能出现截断或异常颜色。"), isOn: $draft.confirmedExtremeValues).font(.callout) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(L10n.text("取消")) { preview.close(); finish(nil) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("确认兼容导入")) { preview.close(); finish(draft) }
                    .buttonStyle(.borderedProminent).disabled(!canConfirm).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("look.compatibility.confirm")
            }.controlSize(.large)
        }.padding(20).pickerStyle(.menu).tint(.yellow)
            .frame(minWidth: 280, idealWidth: 840, maxWidth: 1100, idealHeight: 800)
            .onAppear {
                guard !started else { return }; started = true
                if let initialPhoto { preview.load(lut: sourceURL, source: initialPhoto, draft: originalDraft) }
            }
            .onDisappear { preview.close() }
            .onChange(of: draft.contract) { _, _ in
                conditions.sameProcessing = false
                preview.preview(draft)
            }
            .onChange(of: conditions) { _, _ in preview.compare(draft, conditions: LUTReferenceConditions()) }
            .fileImporter(isPresented: $pickingPhoto, allowedContentTypes: [.image, .rawImage]) { result in
                if case .success(let url) = result {
                    selectPhoto(LUTPreviewSource(url: url))
                }
            }
            .fileImporter(isPresented: $pickingReference, allowedContentTypes: [.jpeg, .png, .tiff]) { result in
                if case .success(let url) = result { conditions = LUTReferenceConditions(); preview.loadReference(url) }
            }
    }
    private func selectPhoto(_ source: LUTPreviewSource) {
        draft = originalDraft; conditions = LUTReferenceConditions()
        preview.load(lut: sourceURL, source: source, draft: originalDraft)
    }
    private var sourceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(L10n.text(chooseLibraryPhoto == nil ? (preview.sourceName == nil ? "选择预览照片" : "更换预览照片") : "从照片库选择")) {
                    if let chooseLibraryPhoto { chooseLibraryPhoto(selectPhoto) }
                    else { pickingPhoto = true }
                }.accessibilityIdentifier("look.compatibility.photo")
                if let name = preview.sourceName { Text(name).font(.caption).lineLimit(2).textSelection(.enabled) }
            }
            Text(L10n.text(preview.displayInput ?
                "预览条件：已显影照片，无额外调整，LUT 强度 100%，输出 sRGB，长边 512 像素。" :
                "预览条件：C5 显影，相机白平衡，场景曝光归一化，曝光 0，无额外调整，LUT 强度 100%，输出 sRGB，长边 512 像素。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if preview.sourceName == nil { Text(L10n.text("选择一张照片即可比较方案；也可以展开高级设置手动配置。")) .font(.callout).foregroundStyle(.secondary) }
        }
    }
    private var candidates: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("候选效果")).font(.headline)
                if preview.isLoading { ProgressView().controlSize(.small); Text(L10n.text("正在生成预览…")).font(.caption) }
            }
            Text(L10n.text("排列顺序不代表准确度。未识别的颜色空间、范围和基础图像仍属于假设。")) .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(Array((showAll ? candidateList : Array(candidateList.prefix(4))).enumerated()), id: \.element.id) { index, candidate in
                    candidateButton(candidate, index: index + 1)
                }
            }
            if candidateList.count > 4 { Button(L10n.text(showAll ? "收起其他方案" : "查看其他方案（包括 Log 输入）")) { showAll.toggle() } }
            if candidateList.isEmpty { Text(L10n.text("没有与此照片类型匹配的候选，请更换照片或检查高级设置。")) .font(.callout).foregroundStyle(.secondary) }
        }
    }
    private func candidateButton(_ candidate: LUTCompatibilityCandidate, index: Int) -> some View {
        let configured = originalDraft.applying(candidate, displayInput: preview.displayInput)
        let frame = configured.flatMap { preview.frame(for: $0) }
        let key = configured.map(LUTCompatibilityPreviewModel.key) ?? ""
        let selected = configured?.contract == draft.contract
        return Button { if let configured { draft = configured } } label: {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let image = frame?.image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                    else { Rectangle().fill(.quaternary).overlay(Image(systemName: "photo").foregroundStyle(.secondary)) }
                }.frame(maxWidth: .infinity).frame(height: 110)
                HStack {
                    Text(L10n.format("方案 %@", String(index))).font(.subheadline.weight(.semibold)); Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.yellow) }
                }
                Text(candidate.basisName).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let failure = preview.failures[key] { Text(failure).font(.caption).foregroundStyle(.red) }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Color.yellow.opacity(0.09) : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.yellow : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 1))
        }.buttonStyle(.plain).disabled(frame == nil)
            .accessibilityLabel(L10n.format("方案 %@", String(index)) + " · " + candidate.basisName)
            .accessibilityIdentifier("look.compatibility.\(candidate.id)")
    }
    private func imagePane(_ frame: LUTPreviewFrame?, title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline)
            Group {
                if let image = frame?.image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                else { Rectangle().fill(.quaternary).overlay(Text(L10n.text("选择照片和方案后显示预览")).font(.caption).foregroundStyle(.secondary).padding()) }
            }.frame(maxWidth: .infinity).frame(height: 200)
        }
    }
    private var referenceControls: some View {
        DisclosureGroup(L10n.text("对照参考图（可选）"), isExpanded: $referenceExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Button(L10n.text("选择参考图")) { pickingReference = true }.accessibilityIdentifier("look.compatibility.reference")
                if let name = preview.referenceName { Text(name).font(.caption).textSelection(.enabled) }
                Text(L10n.text("可先目视比较。计算差异前，请核对以下条件；结果只描述此预览与参考的接近程度，不认证作者效果。")) .font(.callout).foregroundStyle(.secondary)
                Toggle(L10n.text("参考图来自同一张原图"), isOn: $conditions.sameSource)
                Toggle(L10n.text("方向、裁切和构图一致"), isOn: $conditions.sameGeometry)
                Toggle(L10n.text("基础显影、白平衡、曝光和 LUT 强度与上述预览条件一致"), isOn: $conditions.sameProcessing)
                Toggle(L10n.text("参考输出为 sRGB，或已按正确配置转换为 sRGB"), isOn: $conditions.knownSRGB)
                TextField(L10n.text("参考来源、软件版本及处理条件"), text: $conditions.referenceSource, axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.roundedBorder).accessibilityIdentifier("look.compatibility.reference-notes")
                Button(L10n.text("计算与参考的差异")) { preview.compare(draft, conditions: conditions) }
                    .disabled(!conditions.canCompare || preview.reference == nil || preview.frame(for: draft) == nil)
                    .accessibilityIdentifier("look.compatibility.compare")
                if let report = preview.comparison {
                    Text(L10n.format("平均差异 %@/255 · 最大差异 %@/255", String(format: "%.2f", report.meanAbsoluteRGB * 255), String(format: "%.2f", report.maxAbsoluteRGB * 255)))
                    Text(L10n.format("通道边界像素：方案 %@%% · 参考 %@%%", String(format: "%.1f", report.candidateBoundaryFraction * 100), String(format: "%.1f", report.referenceBoundaryFraction * 100)))
                    Text(L10n.text("边界比例仅供观察，不能据此判定配置或风格错误。")).font(.caption).foregroundStyle(.secondary)
                    Text(L10n.text("按已确认条件比较缩小后的 sRGB 像素；差异越小表示越接近此参考，效果仍未验证。")) .font(.caption).foregroundStyle(.secondary)
                }
                if let error = preview.comparisonError { Text(error).font(.callout).foregroundStyle(.red) }
            }.padding(.top, 12).font(.callout)
        }.accessibilityIdentifier("look.compatibility.reference-section")
    }
    private var advancedFields: some View {
        VStack(alignment: .leading, spacing: 12) {
                    if draft.fixedContract {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent(L10n.text("输入颜色"), value: LUTCompatibility.spaceName(draft.contract.input.space))
                            if draft.contract.input.space == "linear-srgb" {
                                LabeledContent(L10n.text("输入参考"), value: L10n.text(draft.contract.input.reference == "scene" ? "场景线性" : "显示图像"))
                            }
                            LabeledContent(L10n.text("输入范围"), value: rangeName(draft.contract.input.range))
                            LabeledContent(L10n.text("输出颜色"), value: LUTCompatibility.spaceName(draft.contract.output.space))
                            if draft.contract.output.space == "linear-srgb" {
                                LabeledContent(L10n.text("输出参考"), value: L10n.text(draft.contract.output.reference == "scene" ? "场景线性" : "显示图像"))
                            }
                            LabeledContent(L10n.text("输出范围"), value: rangeName(draft.contract.output.range))
                            LabeledContent(L10n.text("插值方式"), value: L10n.text(draft.contract.interpolation == "linear" ? "三线性" : "四面体"))
                            if draft.contract.input.reference == "display" {
                                LabeledContent(L10n.text("基础图像"), value: L10n.text(draft.contract.baseRendering == "source-display" ? "已显影的照片（JPEG 等）" : "RawLab 中性显影（近似）"))
                            }
                        }
                    } else { VStack(alignment: .leading, spacing: 12) {
                        spacePicker(L10n.text("输入颜色"), value: draft.contract.input.space) { draft.contract.selectInput($0) }
                        if draft.contract.input.space == "linear-srgb" {
                            referencePicker(L10n.text("输入参考"), value: $draft.contract.input.reference)
                                .onChange(of: draft.contract.input.reference) { _, reference in
                                    draft.contract.baseRendering = reference == "scene" ? "none" : "rawlab-neutral-v1"
                                }
                        }
                        rangePicker(L10n.text("输入范围"), value: $draft.contract.input.range)
                        spacePicker(L10n.text("输出颜色"), value: draft.contract.output.space) { draft.contract.selectOutput($0) }
                        if draft.contract.output.space == "linear-srgb" {
                            referencePicker(L10n.text("输出参考"), value: $draft.contract.output.reference)
                        }
                        rangePicker(L10n.text("输出范围"), value: $draft.contract.output.range)
                        Picker(L10n.text("插值方式"), selection: $draft.contract.interpolation) {
                            Text(L10n.text("三线性")).tag("linear")
                            Text(L10n.text("四面体")).tag("tetrahedral")
                        }
                        if draft.contract.input.reference == "display" {
                            Picker(L10n.text("基础图像"), selection: $draft.contract.baseRendering) {
                                Text(L10n.text("RawLab 中性显影（近似）")).tag("rawlab-neutral-v1")
                                Text(L10n.text("已显影的照片（JPEG 等）")).tag("source-display")
                            }
                        }
                    } }

        }
    }
    private func spacePicker(_ title: String, value: String, select: @escaping (String) -> Void) -> some View {
        Picker(title, selection: Binding(get: { value }, set: select)) {
            Text(L10n.text("请选择")).tag("")
            ForEach(LUTCompatibility.spaces, id: \.self) { space in
                Text(LUTCompatibility.spaceName(space)).tag(space)
            }
        }
    }
    private func rangePicker(_ title: String, value: Binding<String>) -> some View {
        Picker(title, selection: value) {
            Text(L10n.text("完整范围")).tag("full")
            Text(L10n.text("视频范围（10 位 64–940）")).tag("legal10")
        }
    }
    private func rangeName(_ value: String) -> String { L10n.text(value == "full" ? "完整范围" : "视频范围（10 位 64–940）") }
    private func referencePicker(_ title: String, value: Binding<String>) -> some View {
        Picker(title, selection: value) {
            Text(L10n.text("场景线性")).tag("scene")
            Text(L10n.text("显示图像")).tag("display")
        }
    }
}
