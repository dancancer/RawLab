import SwiftUI

struct LensControls: View {
    @ObservedObject var model: EditorModel
    @State private var choosingProfile = false

    private var settings: LensCorrectionSettings { model.lensDraftSettings }
    private var info: LensInfo? { model.result?.lensInfo }

    var body: some View {
        LensDraftWorkspace(settings: settings, info: info, previewIsCurrent: model.lensDraftPreviewIsCurrent,
                           update: model.updateLensDraft, choose: { choosingProfile = true })
            .sheet(isPresented: $choosingProfile) {
                LensProfileChooser(candidates: info?.candidates ?? [], settings: settings,
                    cancel: { choosingProfile = false }, use: { candidate in
                        model.updateLensDraft { $0 = MacLensChooserState.applying(candidate, to: $0) }
                        choosingProfile = false
                    })
            }
    }
}

/// The same workspace can be rendered with an immutable catalog fixture for
/// offscreen layout checks without opening an editor or changing a saved edit.
struct LensDraftWorkspace: View {
    @Environment(\.locale) private var localizationLocale
    let settings: LensCorrectionSettings
    let info: LensInfo?
    let previewIsCurrent: Bool
    let update: ((inout LensCorrectionSettings) -> Void) -> Void
    let choose: () -> Void

    private var presentation: MacLensPresentation {
        MacLensPresentation(settings: settings, info: info, previewIsCurrent: previewIsCurrent)
    }

    var body: some View {
        let _ = localizationLocale
        VStack(alignment: .leading, spacing: 12) {
            LensWorkspaceLayout { identity; correctionOptions }
            Divider()
            Text(presentation.correctionStatus)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("lens.status")
        }.frame(maxWidth: 980, alignment: .leading).padding(.horizontal, 16)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L10n.text(settings.mode == .automatic ? "自动匹配" : "手动选择"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).accessibilityIdentifier("lens.mode")
                Spacer(minLength: 4)
                Text("Lensfun").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Label(presentation.selectedTitle, systemImage: "viewfinder")
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("lens.identity")
            Text(L10n.text(presentation.identityStatusKey))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("lens.matchStatus")
            if let info {
                HStack(spacing: 6) {
                    if !info.detectedLens.isEmpty {
                        Text(info.detectedLens).lineLimit(2).truncationMode(.middle)
                    }
                    if info.focalLength.isFinite, info.focalLength > 0 {
                        Text("\(info.focalLength.formatted(.number.precision(.fractionLength(0...1)))) mm")
                            .monospacedDigit().fixedSize()
                    }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("lens.metadata")
            }
            Menu {
                Button(L10n.text("自动匹配")) { update { $0.mode = .automatic } }
                    .disabled(settings.mode == .automatic)
                Button(L10n.text("选择镜头…"), action: choose)
                    .disabled(info?.candidates.isEmpty != false)
            } label: {
                HStack(spacing: 5) {
                    Text(L10n.text("更换镜头…"))
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }
            }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                .foregroundStyle(.yellow).font(.system(size: 12))
                .help(L10n.text("选择镜头配置文件"))
                .accessibilityLabel(L10n.text("选择镜头配置文件"))
                .accessibilityIdentifier("lens.profile")
                .accessibilityValue(presentation.selectedTitle)
                .disabled(info == nil)
        }
    }

    private var correctionOptions: some View {
        HStack(alignment: .top, spacing: 18) { distortion; tca; autoCrop }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var distortion: some View {
        correctionOption("畸变矫正", detail: presentation.correctionDetailKey(tca: false),
            value: value(\.distortion), enabled: presentation.canChangeCorrection(tca: false),
            identifier: "lens.distortion")
    }

    private var tca: some View {
        correctionOption("横向色差", detail: presentation.correctionDetailKey(tca: true),
            value: value(\.tca), enabled: presentation.canChangeCorrection(tca: true), identifier: "lens.tca")
    }

    private var autoCrop: some View {
        VStack(alignment: .leading, spacing: 5) {
            correctionToggle("自动裁边", value: value(\.autoCrop), enabled: settings.isEnabled, identifier: "lens.crop")
            Text(L10n.text(settings.isEnabled ? "校正后裁去空白边缘" : "先开启畸变或横向色差校正"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let crop = presentation.cropPercent {
                Text(L10n.format("裁边 %@%%", String(crop)))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
        }.frame(minWidth: 118, maxWidth: 150, alignment: .leading)
            .help(L10n.text(settings.isEnabled ? "校正后裁去空白边缘" : "先开启畸变或横向色差校正"))
    }

    private func correctionOption(_ title: String, detail: String, value: Binding<Bool>,
                                  enabled: Bool, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            correctionToggle(title, value: value, enabled: enabled, identifier: identifier)
            Text(L10n.text(detail)).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(minWidth: 118, maxWidth: 150, alignment: .leading)
            .help(L10n.text(detail))
    }

    private func correctionToggle(_ title: String, value: Binding<Bool>, enabled: Bool, identifier: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(L10n.text(title)).font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Toggle(L10n.text(title), isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel(L10n.text(title)).accessibilityIdentifier(identifier).disabled(!enabled)
        }
    }

    private func value(_ keyPath: WritableKeyPath<LensCorrectionSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: keyPath] }, set: { enabled in
            update { $0[keyPath: keyPath] = enabled }
        })
    }
}

/// Measure labels with their actual column widths, including long localized
/// captions, then place both sections at the top of the available workspace.
private struct LensWorkspaceLayout: Layout {
    private let identityWidth: CGFloat = 300
    private let horizontalGap: CGFloat = 20
    private let verticalGap: CGFloat = 12
    private let minimumHorizontalWidth: CGFloat = 710

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 948
        guard subviews.count == 2 else { return .zero }
        if width >= minimumHorizontalWidth {
            let left = subviews[0].sizeThatFits(ProposedViewSize(width: identityWidth, height: nil))
            let right = subviews[1].sizeThatFits(ProposedViewSize(width: width - identityWidth - horizontalGap, height: nil))
            return CGSize(width: width, height: max(left.height, right.height))
        }
        let left = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let right = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: left.height + verticalGap + right.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        if bounds.width >= minimumHorizontalWidth {
            subviews[0].place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: identityWidth, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX + identityWidth + horizontalGap, y: bounds.minY),
                              anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width - identityWidth - horizontalGap, height: nil))
        } else {
            let left = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + left.height + verticalGap),
                              anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

struct LensProfileChooser: View {
    @Environment(\.locale) private var localizationLocale
    let candidates: [LensCandidate]
    let cancel: () -> Void
    let use: (LensCandidate) -> Void
    @State private var state: MacLensChooserState

    init(candidates: [LensCandidate], settings: LensCorrectionSettings,
         cancel: @escaping () -> Void, use: @escaping (LensCandidate) -> Void) {
        self.candidates = candidates
        self.cancel = cancel
        self.use = use
        _state = State(initialValue: MacLensChooserState(settings: settings, candidates: candidates))
    }

    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack {
                    Text(L10n.text("选择镜头")).font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button(action: cancel) { Image(systemName: "xmark").frame(width: 20, height: 20) }
                        .buttonStyle(.borderless).help(L10n.text("关闭镜头选择"))
                        .accessibilityLabel(L10n.text("关闭镜头选择"))
                        .accessibilityIdentifier("lens.chooser.close")
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L10n.text("搜索镜头"), text: $state.query).textFieldStyle(.plain)
                        .accessibilityLabel(L10n.text("搜索镜头"))
                        .accessibilityIdentifier("lens.search")
                }.padding(9).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            }.padding(16)
            Divider()
            if state.filtered(candidates).isEmpty {
                Text(L10n.text("未找到镜头")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(state.filtered(candidates)) { candidate in
                            candidateRow(candidate)
                            Divider()
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Text(L10n.text("选择镜头只更新草稿，应用后保存"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(L10n.text("取消"), action: cancel).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("lens.chooser.cancel")
                Button(L10n.text("使用此镜头")) {
                    if let candidate = state.usableCandidate(in: candidates) { use(candidate) }
                }.buttonStyle(.borderedProminent).tint(.yellow).keyboardShortcut(.defaultAction)
                    .disabled(state.usableCandidate(in: candidates) == nil)
                    .accessibilityIdentifier("lens.chooser.use")
            }.padding(16)
        }.frame(width: 540, height: 440)
    }

    private func candidateRow(_ candidate: LensCandidate) -> some View {
        let selected = candidate.id == state.selectedID
        return Button { state.select(candidate.id, candidates: candidates) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(candidate.title).font(.system(size: 13)).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(MacLensChooserState.capabilityKeys(for: candidate).map { L10n.text($0) }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if candidate.isMatch {
                    Text(L10n.text("自动匹配")).font(.system(size: 11)).foregroundStyle(.yellow)
                        .fixedSize()
                }
                Image(systemName: selected ? "checkmark" : "circle")
                    .foregroundStyle(selected ? Color.yellow : Color.clear).frame(width: 14)
            }.padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Color.yellow.opacity(0.14) : Color.clear)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(candidate.title)
            .accessibilityValue(MacLensChooserState.capabilityKeys(for: candidate).map { L10n.text($0) }.joined(separator: ", "))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("lens.candidate.\(candidate.id)")
    }
}
