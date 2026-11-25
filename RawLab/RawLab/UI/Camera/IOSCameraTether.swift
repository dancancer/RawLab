import RawLabKit
import SwiftUI

struct IOSCameraTether: View {
    @ObservedObject var model: IOSCameraController
    let openOriginal: (CameraStoredOriginal) -> Void
    let history: () -> Void
    let storage: () -> Void
    let reconnect: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var grid = false
    @State private var automaticReview = false
    @State private var parameters = false
    @State private var parameter: IOSCameraParameter?
    @State private var previewOriginal: CameraStoredOriginal?
    private var cameraName: String { model.device?.model == "ILCE-7CM2" ? "α7C II" : model.device?.model ?? "Sony" }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height
            Group {
                if wide {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            viewfinder.frame(maxWidth: .infinity, maxHeight: .infinity)
                            parameterBar
                            status
                        }
                        ScrollView {
                            VStack(spacing: 12) { recentButton; shutter; parameterButton }
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }.frame(width: 96)
                    }
                } else {
                    VStack(spacing: 0) {
                        viewfinder.frame(maxWidth: .infinity, maxHeight: .infinity)
                        parameterBar
                        HStack {
                            recentButton; Spacer(); shutter; Spacer(); parameterButton
                        }.padding(.horizontal, 32).frame(height: 108)
                        status
                    }
                }
            }.background(Color(white: 0.14))
        }
        .navigationTitle(L10n.format("%@ · 联机", cameraName)).navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { model.stop(); dismiss() } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel(L10n.text("返回")).accessibilityIdentifier("camera.tether.back")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(L10n.text("更换相机"), action: reconnect)
                    Button(L10n.text("保存位置"), action: storage)
                    Button(L10n.text("导入记录"), action: history)
                    Button(L10n.text("断开连接")) { model.stop() }
                    Divider()
                    Toggle(L10n.text("构图网格"), isOn: $grid)
                    Toggle(L10n.text("拍后审片"), isOn: $automaticReview)
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel(L10n.text("更多"))
                    .accessibilityIdentifier("camera.tether.menu")
            }
        }
        .sheet(isPresented: $parameters) {
            NavigationStack {
                List {
                    ForEach([IOSCameraParameter.whiteBalance, .focus, .focusArea, .temperature].filter {
                        ($0 != .temperature && $0 != .focusArea) || $0.descriptor(in: model.properties) != nil
                    }) { item in
                        Button {
                            parameters = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { parameter = item }
                        } label: {
                            HStack {
                                Text(item.title).foregroundStyle(.primary); Spacer()
                                Text(item.descriptor(in: model.properties)?.number.map(item.display) ?? "—")
                                    .foregroundStyle(.secondary).monospacedDigit()
                                Image(systemName: "chevron.right")
                            }.frame(minHeight: 44)
                        }
                    }
                }.navigationTitle(L10n.text("拍摄参数")).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("关闭")) { parameters = false } } }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $parameter) { item in
            IOSCameraParameterPicker(model: model, parameter: item)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $previewOriginal) { original in
            let index = model.recentTetherOriginals.firstIndex(where: { $0.id == original.id })
            let sizeText = ByteCountFormatter.string(fromByteCount: Int64(original.size), countStyle: .file)
            let countText = index.map { "\($0 + 1) / \(model.recentTetherOriginals.count)" }
            let detail = [sizeText, countText].compactMap { $0 }.joined(separator: " · ")
            IOSCameraPreview(model: model, name: original.name, detail: detail) {
                HStack {
                    Button { reviewNeighbor(original, offset: 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(!hasNeighbor(original, offset: 1)).accessibilityLabel(L10n.text("上一张"))
                    Spacer()
                    Button(L10n.text("打开编辑")) { previewOriginal = nil; openOriginal(original) }
                        .disabled(original.availability != .available)
                    Spacer()
                    Button { reviewNeighbor(original, offset: -1) } label: { Image(systemName: "chevron.right") }
                        .disabled(!hasNeighbor(original, offset: -1)).accessibilityLabel(L10n.text("下一张"))
                }
            }
        }
        .onChange(of: model.latestOriginal?.id) { _, _ in
            guard automaticReview, previewOriginal == nil, !parameters, parameter == nil, let original = model.latestOriginal else { return }
            review(original)
        }
        .accessibilityIdentifier("camera.tether")
    }

    private var viewfinder: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let live = model.connected && model.phase != .receiving &&
                model.frameAt.map { timeline.date.timeIntervalSince($0) <= 5 } == true
            GeometryReader { geometry in
                ZStack {
                    Color.black
                    if let frame = model.frame {
                        let imageSize = frame.size
                        let scale = min(geometry.size.width / max(1, imageSize.width),
                                        geometry.size.height / max(1, imageSize.height))
                        let fittedWidth = imageSize.width * scale
                        let fittedHeight = imageSize.height * scale
                        let left = (geometry.size.width - fittedWidth) / 2
                        let top = (geometry.size.height - fittedHeight) / 2
                        Image(uiImage: frame).resizable().scaledToFit().opacity(live ? 1 : 0.48)
                        if grid {
                            Path { path in
                                for index in 1...2 {
                                    let p = CGFloat(index) / 3
                                    path.move(to: CGPoint(x: left + fittedWidth * p, y: top))
                                    path.addLine(to: CGPoint(x: left + fittedWidth * p, y: top + fittedHeight))
                                    path.move(to: CGPoint(x: left, y: top + fittedHeight * p))
                                    path.addLine(to: CGPoint(x: left + fittedWidth, y: top + fittedHeight * p))
                                }
                            }.stroke(.white.opacity(0.35), lineWidth: 0.5).allowsHitTesting(false)
                        }
                        if live {
                            Canvas { context, _ in
                                context.clip(to: Path(CGRect(x: left, y: top, width: fittedWidth, height: fittedHeight)))
                                let green = Color(red: 0.20, green: 0.84, blue: 0.35)
                                let white = Color.white.opacity(0.92)
                                let backing = Color.black.opacity(0.45)
                                switch model.focusRenderContent(
                                    left: left,
                                    top: top,
                                    fittedWidth: fittedWidth,
                                    fittedHeight: fittedHeight
                                ) {
                                case .frames(let items):
                                    for item in items {
                                        let rect = CGRect(x: item.box.x, y: item.box.y, width: item.box.width, height: item.box.height)
                                        let lineWidth: CGFloat = item.focused ? 2 : 1.5
                                        let strokeColor: Color = item.focused ? green : white
                                        context.stroke(Path(rect), with: .color(backing), lineWidth: lineWidth + 1.5)
                                        context.stroke(Path(rect), with: .color(strokeColor), lineWidth: lineWidth)
                                    }
                                case .tapReticle(let box, let focused):
                                    let rect = CGRect(x: box.x, y: box.y, width: box.width, height: box.height)
                                    let lineWidth: CGFloat = focused ? 2 : 1.75
                                    let strokeColor: Color = focused ? green : white
                                    context.stroke(Path(rect), with: .color(backing), lineWidth: lineWidth + 1.5)
                                    context.stroke(Path(rect), with: .color(strokeColor), lineWidth: lineWidth)
                                case .none:
                                    break
                                }
                            }
                            .allowsHitTesting(false)
                            .accessibilityIdentifier("camera.tether.focusOverlay")
                        }
                    } else if model.connected && model.properties[0xd278]?.text != nil {
                        ProgressView().tint(.white)
                    } else if model.connected {
                        Text(L10n.text("相机未提供实时取景，其他可用功能仍可使用。"))
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    guard live, model.phase == .ready, !model.busy, let frame = model.frame else { return }
                    guard let tap = CameraWire.focusPoint(
                        tapX: location.x,
                        tapY: location.y,
                        containerWidth: geometry.size.width,
                        containerHeight: geometry.size.height,
                        imageWidth: frame.size.width,
                        imageHeight: frame.size.height
                    ) else { return }
                    model.setFocusPoint(u: tap.u, v: tap.v, x: tap.x, y: tap.y)
                }
                .overlay {
                    if !model.connected {
                        VStack(spacing: 10) {
                            Text(L10n.text("联机已暂停")).font(.headline)
                            Text(L10n.format("已保存 %d 张", model.recentTetherOriginals.count))
                                .font(.caption).foregroundStyle(.secondary)
                            Button(L10n.text("重新连接"), action: reconnect)
                                .buttonStyle(.borderedProminent)
                                .foregroundStyle(.black)
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("camera.tether.reconnect")
                        }
                        .padding(20)
                        .background(Color(white: 0.12).opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.14), lineWidth: 1) }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if model.connected {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(live ? Color(red: 0.20, green: 0.84, blue: 0.35) : Color.secondary)
                                .frame(width: 6, height: 6)
                            Text(live ? "LIVE" : L10n.text("取景已暂停")).font(.caption2.weight(.medium))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5))
                        .padding(10)
                        .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if live && model.canCancelTouchFocus {
                        Button { model.cancelTouchFocus() } label: {
                            Label(L10n.text("取消对焦"), systemImage: "xmark")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .background(.black.opacity(0.68), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.focusBusy || model.phase != .ready)
                        .padding(10)
                        .accessibilityIdentifier("camera.tether.cancelFocus")
                    }
                }
            }
        }.accessibilityIdentifier("camera.liveview")
    }

    private var parameterBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                ForEach(Array(IOSCameraParameter.allCases.prefix(4))) { item in
                    let descriptor = item.descriptor(in: model.properties)
                    let isEditable = model.writable && descriptor?.writable == true && descriptor?.enabled == 1 && descriptor?.selectableValues.isEmpty == false
                    Button { parameter = item } label: {
                        Text(descriptor?.number.map { compactValue(item, $0) } ?? "—")
                            .font(.system(size: 16)).monospacedDigit()
                            .foregroundStyle(isEditable ? Color.primary : Color.secondary.opacity(0.65))
                            .lineLimit(1).minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity, minHeight: 56).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(model.parameterBusy || model.focusBusy).accessibilityIdentifier("camera.parameter.\(item.code)")
                }
            }
            .overlay(alignment: .topTrailing) {
                if model.parameterBusy {
                    ProgressView().controlSize(.mini).padding(6)
                }
            }
            Divider()
        }
        .background(Color(white: 0.11))
    }
    private var shutter: some View {
        let capturing = model.phase == .capturing || model.phase == .waiting
        return Button { model.capture() } label: {
            Circle().stroke(model.canCapture ? Color.white : Color.gray, lineWidth: 2)
                .overlay(Circle().fill(model.canCapture ? Color.white : Color.gray.opacity(0.4)).padding(6))
                .overlay {
                    if capturing { ProgressView().tint(.white) }
                }
                .frame(width: 68, height: 68)
        }.buttonStyle(.plain).disabled(!model.canCapture)
            .accessibilityLabel(L10n.text("拍摄一张")).accessibilityIdentifier("camera.shutter")
    }
    private var recentButton: some View {
        let original = model.recentTetherOriginals.first
        return Button { if let original { review(original) } } label: {
            ZStack {
                Rectangle().fill(Color(white: 0.08))
                if let original, let image = model.thumbnails[original.id.uuidString] { Image(uiImage: image).resizable().scaledToFill() }
                else { Image(systemName: "photo.on.rectangle").foregroundStyle(.secondary) }
            }.frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain).disabled(original == nil).accessibilityLabel(L10n.text("最近照片"))
            .accessibilityIdentifier("camera.tether.recent").task(id: original?.id) { if let original { model.thumbnail(original) } }
    }
    private var parameterButton: some View {
        Button { parameters = true } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 22)).frame(width: 48, height: 48) }
            .buttonStyle(.plain).accessibilityLabel(L10n.text("拍摄参数")).accessibilityIdentifier("camera.parameters")
    }
    private var status: some View {
        let savedCount = model.recentTetherOriginals.count
        let savedLabel = L10n.format("已保存 %d 张", savedCount)
        let hasSavedToPhotos = model.recentTetherOriginals.contains { $0.photoLibraryAssetID != nil }
        return VStack(spacing: 4) {
            HStack {
                Text(L10n.text(statusTitle)); Spacer(minLength: 4)
                Text(hasSavedToPhotos && !model.photoLibraryPermissionDenied
                     ? L10n.format("%@ · %@", savedLabel, L10n.text("已保存到相册"))
                     : savedLabel)
                if pendingCount > 0 { Text(L10n.format("待接收 %d 张。", pendingCount)) }
            }.font(.caption2).foregroundStyle(.secondary).frame(minHeight: 28)
            if let progress = model.progress, model.phase == .receiving {
                ProgressView(value: Double(progress.bytes), total: Double(progress.total)).accessibilityLabel(L10n.text("正在接收原件"))
            }
            if model.parameterBusy { Text(L10n.text("正在更新相机设置…")).font(.caption2).foregroundStyle(.secondary) }
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("camera.tether.notice")
                if model.photoLibraryPermissionDenied {
                    Button(L10n.text("系统权限设置")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .font(.caption)
                }
            } else if model.connected && !model.originalBrowsingAvailable {
                Text(L10n.text("此连接方式不能接收卡内原件，软件快门已停用。")).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 16).padding(.bottom, 4)
    }
    private var pendingCount: Int {
        let ids = Set(model.manifest.tether?.jobIDs ?? [])
        return model.manifest.jobs.filter { ids.contains($0.id) }.flatMap(\.items).filter { $0.phase != .saved }.count
    }
    private var statusTitle: String {
        switch model.phase {
        case .ready: return "已连接 · 自动接收原件"
        case .capturing: return "正在拍摄"
        case .waiting: return "等待相机保存"
        case .receiving: return "正在接收原件"
        case .connecting: return "正在准备取景"
        default: return "联机已暂停"
        }
    }
    private func compactValue(_ item: IOSCameraParameter, _ value: Int64) -> String {
        let text = item.display(value)
        if item == .shutter { return text.replacingOccurrences(of: " s", with: "") }
        if item == .iso { return "ISO " + text }
        return text
    }
    private func review(_ original: CameraStoredOriginal) { model.showPreview(original); previewOriginal = original }
    private func hasNeighbor(_ original: CameraStoredOriginal, offset: Int) -> Bool {
        guard let index = model.recentTetherOriginals.firstIndex(where: { $0.id == original.id }) else { return false }
        return model.recentTetherOriginals.indices.contains(index + offset)
    }
    private func reviewNeighbor(_ original: CameraStoredOriginal, offset: Int) {
        guard let index = model.recentTetherOriginals.firstIndex(where: { $0.id == original.id }), hasNeighbor(original, offset: offset) else { return }
        review(model.recentTetherOriginals[index + offset])
    }
}

private struct IOSCameraParameterPicker: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: IOSCameraController
    let parameter: IOSCameraParameter
    private var descriptor: CameraProperty? { parameter.descriptor(in: model.properties) }
    private var values: [Int64] { descriptor?.selectableValues.filter { parameter != .shutter || $0 != 0 } ?? [] }
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        HStack {
                            Text(parameter.title); Spacer()
                            Text(descriptor?.number.map(parameter.display) ?? "—").monospacedDigit()
                        }
                    }
                    if !model.writable || descriptor?.writable != true || values.isEmpty || descriptor?.enabled != 1 {
                        Section { Text(L10n.text(values.isEmpty ? "相机未提供可调整选项" : "当前拍摄模式下不可调整")).foregroundStyle(.secondary) }
                    } else {
                        Section {
                            ForEach(values, id: \.self) { value in
                                let isCurrent = descriptor?.number == value
                                Button {
                                    guard let descriptor else { return }
                                    model.setParameter(descriptor, value: value); dismiss()
                                } label: {
                                    HStack {
                                        Text(parameter.display(value))
                                            .monospacedDigit()
                                            .foregroundStyle(isCurrent ? Color.yellow : Color.primary)
                                        Spacer()
                                        if isCurrent {
                                            Image(systemName: "checkmark").foregroundStyle(.yellow)
                                        }
                                    }
                                    .frame(minHeight: 44)
                                }.disabled(model.busy || model.phase != .ready)
                                    .id(value)
                            }
                        }
                    }
                }
                .onAppear {
                    if let current = descriptor?.number, values.contains(current) {
                        DispatchQueue.main.async { proxy.scrollTo(current, anchor: .center) }
                    }
                }
            }.navigationTitle(parameter.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("关闭")) { dismiss() } } }
        }
    }
}
