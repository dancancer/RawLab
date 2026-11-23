import RawLabKit
import SwiftUI
import UniformTypeIdentifiers

struct IOSCameraWorkspace: View {
    enum Route: Hashable { case connect, help, manual, importer, tether, history, storage }
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = IOSCameraController()
    @StateObject private var connection = IOSCameraConnection()
    @State private var path: [Route] = []
    @State private var mode = IOSCameraMode.importing
    @State private var cardConfirmed = false
    @State private var resumeTether = false
    @State private var pendingImport: CameraTransferJob?
    @State private var newTetherConfirmation = false
    @State private var confirmClearOriginals = false
    @State private var showHandoffPassword = false
    @State private var handoffPasswordCopied = false
    private var previousCamera: CameraDeviceIdentity? { model.device ?? model.manifest.tether?.camera ?? model.manifest.jobs.last?.camera }
    private var cameraName: String { previousCamera?.model == "ILCE-7CM2" ? "α7C II" : previousCamera?.model ?? L10n.text("相机") }
    let onOpenOriginal: (URL) -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack(path: $path) {
            home.navigationTitle(L10n.text("相机")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { close() } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel(L10n.text("返回")).accessibilityIdentifier("camera.close")
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .connect: connectionPage
                    case .help: IOSCameraConnectionGuide()
                    case .manual: IOSCameraManualWiFi(connection: connection, model: model)
                    case .importer:
                        IOSCameraBrowser(model: model, openOriginal: open, history: { path.append(.history) },
                            storage: { path.append(.storage) }, reconnect: reconnect, resume: resume)
                    case .tether:
                        IOSCameraTether(model: model, openOriginal: open, history: { path.append(.history) },
                            storage: { path.append(.storage) }, reconnect: reconnect)
                    case .history: IOSCameraHistory(model: model, openOriginal: open, resume: resume)
                    case .storage: storagePage
                    }
                }
        }
        .tint(.yellow).preferredColorScheme(.dark)
        .onAppear {
            connection.onEndpoint = { endpoint in
                model.connect(endpoint: endpoint, mode: mode, cardConfirmed: cardConfirmed, resume: resumeTether)
            }
        }
        .onChange(of: model.phase) { _, _ in advanceConnectedRoute() }
        .onChange(of: model.manualImportRequired) { _, required in
            if required && mode == .tethering { connection.stop(); path = [.connect] }
        }
        .onChange(of: path) { old, new in
            let active: Set<Route> = [.importer, .tether]
            if old.contains(where: active.contains), !new.contains(where: active.contains) { model.stop() }
            if old.contains(.connect), !new.contains(.connect), !new.contains(where: active.contains) { connection.stop(); model.stop() }
            advanceConnectedRoute()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { connection.pauseForBackground(); model.stop() }
        }
        .onChange(of: connection.manualWiFiHandoff) { _, _ in
            showHandoffPassword = false
            handoffPasswordCopied = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            connection.stop(); model.stop()
        }
        .onDisappear { connection.stop(); model.stop() }
        .confirmationDialog(L10n.text("开始新的联机"), isPresented: $newTetherConfirmation, titleVisibility: .visible) {
            Button(L10n.text("开始新的联机")) { choose(.tethering, resume: false) }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: { Text(L10n.text("请先检查相机上的拍摄结果。新会话不会补拍，未完成照片可在导入记录中继续接收。")) }
    }
    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(cameraName).font(.title2.weight(.semibold))
                    Text(L10n.text(previousCamera == nil ? "选择连接方式" : "上次使用的相机 · 未连接"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 16).accessibilityIdentifier("camera.identity")
                entry(title: L10n.text("从相机导入"), detail: L10n.text("浏览存储卡，选择并保存照片"), symbol: "photo.on.rectangle.angled", id: "camera.entry.import") {
                    choose(.importing, resume: false)
                }
                entry(title: L10n.text("联机拍摄"), detail: L10n.text("实时取景、调整参数并拍摄"), symbol: "camera.viewfinder", id: "camera.entry.tether") {
                    if model.manifest.tether?.shutterRequestedAt != nil { newTetherConfirmation = true }
                    else { choose(.tethering, resume: false) }
                }
                if model.manifest.canResumeTether {
                    Button { choose(.tethering, resume: true) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.clockwise").foregroundStyle(.yellow)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.text("恢复上次联机")).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                Text(L10n.text("恢复未完成的原件接收，不会自动补拍。")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.yellow.opacity(0.45), lineWidth: 1) }
                    }.buttonStyle(.plain).accessibilityIdentifier("camera.resume.tether")
                }
                VStack(spacing: 0) {
                    Button { path.append(.history) } label: {
                        HStack {
                            Label(L10n.text("导入记录"), systemImage: "clock.arrow.circlepath").foregroundStyle(.primary)
                            Spacer()
                            Text("\(model.originals.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14).frame(minHeight: 48).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("camera.history")
                    Divider().padding(.leading, 44)
                    Button { path.append(.storage) } label: {
                        HStack {
                            Label(L10n.text("保存位置"), systemImage: "folder").foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14).frame(minHeight: 48).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 10))
                Text(L10n.text("相机中的原照片会保留。")).font(.footnote).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
        }.background(Color(white: 0.10)).accessibilityIdentifier("camera.home")
    }
    private func entry(title: String, detail: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.title2).frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0); Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }
    private var connectionPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L10n.text("选择相机")).font(.headline)
                    Spacer()
                    Button(L10n.text("如何连接")) { path.append(.help) }
                        .frame(minHeight: 44).accessibilityIdentifier("camera.help")
                }
                if mode == .tethering {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(L10n.text("已确认相机同时将原件保存到存储卡。"), isOn: $cardConfirmed)
                            .font(.callout).accessibilityIdentifier("camera.card.confirm")
                        if !cardConfirmed {
                            Text(L10n.text("请先确认上方存储卡保存选项"))
                                .font(.caption).foregroundStyle(.yellow)
                        }
                    }
                    .padding(14)
                    .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(cardConfirmed ? Color.clear : Color.yellow.opacity(0.45), lineWidth: 1)
                    }
                }
                if connection.connecting || model.phase == .connecting {
                    HStack {
                        ProgressView()
                        Text(model.device != nil && model.phase == .connecting ? L10n.text("正在扫描相机…")
                             : connection.status.isEmpty ? L10n.text("正在连接相机…") : connection.status)
                    }
                    .font(.callout).padding(.vertical, 8)
                    Button(L10n.text("取消连接")) { connection.stop(); model.stop() }.frame(minHeight: 44)
                } else if let handoff = connection.manualWiFiHandoff {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(L10n.text("已获取相机 Wi-Fi 信息"), systemImage: "wifi").font(.headline)
                            Spacer()
                            if !handoff.label.isEmpty {
                                Text(handoff.label).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("1. 复制下方密码，前往系统「设置 → 无线局域网」加入该网络。")).font(.callout)
                            Text(L10n.text("2. 返回 RawLab，点击“已连接，继续”。")).font(.callout)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("Wi-Fi 名称")).font(.caption).foregroundStyle(.secondary)
                            Text(handoff.ssid).font(.body.monospaced()).textSelection(.enabled)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("Wi-Fi 密码")).font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                Text(showHandoffPassword ? handoff.password : "••••••••")
                                    .font(.body.monospaced())
                                Spacer()
                                Button { showHandoffPassword.toggle() } label: {
                                    Image(systemName: showHandoffPassword ? "eye.slash" : "eye")
                                }
                                .accessibilityLabel(showHandoffPassword ? L10n.text("隐藏密码") : L10n.text("显示密码"))
                                .frame(minWidth: 44, minHeight: 44)
                                Button(handoffPasswordCopied ? L10n.text("已复制") : L10n.text("复制密码")) {
                                    UIPasteboard.general.setItems(
                                        [[UTType.utf8PlainText.identifier: handoff.password]],
                                        options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
                                    )
                                    handoffPasswordCopied = true
                                }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("camera.handoff.copy")
                            }
                            if handoffPasswordCopied {
                                Text(L10n.text("密码已复制，仅本机可用，2 分钟后自动清除。"))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Text(L10n.text("相机 Wi-Fi 通常无法访问互联网，请保持连接。"))
                            .font(.footnote).foregroundStyle(.secondary)
                        let canContinue = mode != .tethering || cardConfirmed
                        Button {
                            model.clearNotice()
                            showHandoffPassword = false
                            handoffPasswordCopied = false
                            connection.continueAfterManualWiFiHandoff()
                        } label: {
                            Text(L10n.text("已连接，继续"))
                                .foregroundStyle(canContinue ? Color.black : Color.secondary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canContinue)
                        .accessibilityIdentifier("camera.handoff.continue")
                        Button(L10n.text("取消连接")) {
                            showHandoffPassword = false
                            handoffPasswordCopied = false
                            connection.stop()
                            model.stop()
                        }
                        .frame(minHeight: 44)
                    }
                    .padding(16)
                    .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(L10n.text("在系统 Wi-Fi 设置连接"), systemImage: "wifi").font(.headline)
                        Text(L10n.text("请先在 iOS「设置 → 无线局域网」连接相机 Wi-Fi，再返回点击“已连接，继续”。"))
                            .font(.callout).foregroundStyle(.secondary)
                        let canContinue = mode != .tethering || cardConfirmed
                        Button {
                            model.clearNotice()
                            connection.useCurrentWiFi()
                        } label: {
                            Text(L10n.text("已连接，继续"))
                                .foregroundStyle(canContinue ? Color.black : Color.secondary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canContinue)
                        .accessibilityIdentifier("camera.connect.continue")
                        Text(L10n.text("相机 Wi-Fi 通常无法访问互联网，请保持连接。"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 10))
                    Divider().padding(.vertical, 4)
                    Text(L10n.text("蓝牙发现相机（可选）")).font(.subheadline.weight(.semibold))
                    Text(L10n.text("通过蓝牙唤醒相机 Wi-Fi；系统自动加入不可用时，可复制密码后在系统设置连接。"))
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(connection.candidates) { candidate in
                        Button {
                            model.clearNotice()
                            connection.connect(candidate)
                        } label: {
                            HStack {
                                Image(systemName: "camera"); Text(candidate.name).foregroundStyle(.primary)
                                Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }.padding(.horizontal, 12).frame(minHeight: 56)
                                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 8))
                        }.disabled(mode == .tethering && !cardConfirmed)
                            .accessibilityIdentifier("camera.candidate")
                    }
                    if connection.searching {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(connection.status.isEmpty ? L10n.text("正在查找相机…") : connection.status)
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    } else if connection.candidates.isEmpty {
                        Text(L10n.text("未发现相机。请打开相机的智能手机连接。")).font(.callout).foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    Button { connection.search() } label: {
                        HStack { if connection.searching { ProgressView() }; Label(L10n.text("查找相机"), systemImage: "arrow.clockwise") }
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered).disabled(connection.searching).accessibilityIdentifier("camera.search")
                    Button { path.append(.manual) } label: {
                        Label(L10n.text("输入 Wi-Fi 名称与密码"), systemImage: "wifi").frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered).disabled(mode == .tethering && !cardConfirmed)
                        .accessibilityIdentifier("camera.manual")
                }
                if !connection.status.isEmpty && !connection.connecting && !connection.searching {
                    Text(connection.status).font(.footnote).foregroundStyle(.secondary)
                }
                if let error = model.manualImportRequired ? model.notice : connection.failure ?? model.notice {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("camera.connection.error")
                        if model.manualImportRequired && mode == .tethering {
                            Button(L10n.text("从相机导入")) { choose(.importing, resume: false) }
                                .frame(minHeight: 44).accessibilityIdentifier("camera.connection.manual-import")
                        } else if connection.failure != nil || model.localNetworkDenied {
                            Button(L10n.text("系统权限设置")) {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }.frame(minHeight: 44)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.45), lineWidth: 1) }
                }
                Text(L10n.text("部分功能不可用时，检查相机模式。已验证型号仅作参考，其他 Sony 相机也可以尝试连接。")).font(.footnote).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.background(Color(white: 0.10))
            .navigationTitle(L10n.text(mode == .importing ? "连接相机以导入" : "连接相机以拍摄")).navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("camera.connect")
    }
    private var storagePage: some View {
        List {
            Section(L10n.text("保存位置")) {
                Label(L10n.text("RawLab 内的相机原件"), systemImage: "folder")
                Text(L10n.text("导入的照片会自动保存到手机相册，并在 RawLab 内保留本地原件以支持离线编辑与增量去重。"))
                    .font(.callout).foregroundStyle(.secondary)
                Text(L10n.text("完整原件保存在 RawLab 的持久存储中，结束联机或清理编辑缓存不会删除它们。"))
                    .font(.callout).foregroundStyle(.secondary)
                // Q6：相机原件不自动删；这里提供列目录与手动清理入口。
                Text(L10n.format("共 %d 个相机原件，占用 %@。", model.storedOriginalsCount,
                                 ByteCountFormatter.string(fromByteCount: Int64(model.storedOriginalsBytes), countStyle: .file)))
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("camera.originals.summary")
                Button(L10n.text("清理已导出的相机原件")) { confirmClearOriginals = true }
                    .disabled(model.busy || model.cleaningOriginals)
                    .accessibilityIdentifier("camera.originals.clear")
                if let cleaned = model.lastOriginalsCleanup {
                    Text(L10n.format("已清理 %d 个文件，释放 %@。", cleaned.originals,
                                     ByteCountFormatter.string(fromByteCount: Int64(cleaned.freedBytes), countStyle: .file)))
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("camera.originals.feedback")
                } else if model.originalsCleanupFailed {
                    Text(L10n.text("清理已导出的相机原件失败，请重试。"))
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("camera.originals.feedback")
                }
            }
            Section {
                Text(L10n.text("从导入记录打开原件进行编辑；原始照片不会被调整覆盖。")).font(.callout)
                Button(L10n.text("导入记录")) { path.append(.history) }
            }
        }.navigationTitle(L10n.text("相机照片保存位置")).navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(L10n.text("确认清理已导出的相机原件？清理后这些原件无法在应用内打开，已导出的照片不受影响。"),
                                isPresented: $confirmClearOriginals, titleVisibility: .visible) {
                Button(L10n.text("清理原件"), role: .destructive) { model.pruneExportedOriginals() }
                    .accessibilityIdentifier("camera.originals.confirm")
                Button(L10n.text("取消"), role: .cancel) {}
            }
    }
    private func choose(_ value: IOSCameraMode, resume: Bool) {
        connection.stop(); model.stop()
        mode = value; resumeTether = resume; cardConfirmed = false; pendingImport = nil
        model.clearNotice(); path = [.connect]; connection.search()
    }
    private func reconnect() {
        connection.stop(); model.stop()
        mode = model.mode
        resumeTether = mode == .tethering && model.manifest.canResumeTether
        model.clearNotice()
        if mode == .tethering && model.manifest.tether != nil && !resumeTether {
            path = []
        } else {
            path = [.connect]; connection.search()
        }
    }
    private func resume(_ job: CameraTransferJob) {
        if model.connected && model.mode == .importing && model.phase == .browsing {
            path = [.importer]; model.resumeImport(job)
        } else {
            choose(.importing, resume: false); pendingImport = job
        }
    }
    private func advanceConnectedRoute() {
        guard path.last == .connect || path.last == .manual else { return }
        if model.phase == .browsing {
            path = [.importer]
            if let job = pendingImport { pendingImport = nil; model.resumeImport(job) }
        } else if mode == .tethering && (model.phase == .ready || model.phase == .waiting) { path = [.tether] }
    }
    private func open(_ original: CameraStoredOriginal) {
        connection.stop()
        model.openOriginal(original) { url in onOpenOriginal(url) }
    }
    private func close() { connection.stop(); model.stop(completion: onClose) }
}

private struct IOSCameraManualWiFi: View {
    @ObservedObject var connection: IOSCameraConnection
    @ObservedObject var model: IOSCameraController
    @State private var ssid = ""
    @State private var password = ""
    private var connecting: Bool { connection.connecting || model.phase == .connecting }
    var body: some View {
        Form {
            Section(L10n.text("输入 Wi-Fi 名称与密码")) {
                Text(connection.hotspotAutoJoinUnavailable
                     ? L10n.text("当前签名未启用系统自动加入 Wi-Fi，请使用上方系统 Wi-Fi 方式连接。")
                     : L10n.text("应用内自动加入需要付费 Apple 开发者账号的 Hotspot 权限；个人免费签名请使用上方系统 Wi-Fi 方式。"))
                .font(.footnote).foregroundStyle(.secondary)
                TextField(L10n.text("Wi-Fi 名称"), text: $ssid).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("camera.wifi.ssid")
                SecureField(L10n.text("Wi-Fi 密码"), text: $password).accessibilityIdentifier("camera.wifi.password")
                Button(L10n.text("连接相机 Wi-Fi")) {
                    model.clearNotice()
                    connection.join(ssid: ssid, password: password)
                    password = ""
                }.disabled(ssid.isEmpty || password.count < 8 || connecting)
                    .accessibilityIdentifier("camera.wifi.join")
            }
            if connecting {
                Section {
                    HStack {
                        ProgressView()
                        Text(model.device != nil && model.phase == .connecting ? L10n.text("正在扫描相机…")
                             : connection.status.isEmpty ? L10n.text("正在连接相机…") : connection.status)
                    }
                    Button(L10n.text("取消连接")) { connection.stop(); model.stop() }
                }
            }
            if let error = model.notice ?? connection.failure {
                Section {
                    Text(error).foregroundStyle(.orange)
                    if model.localNetworkDenied {
                        Button(L10n.text("系统权限设置")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                }
            }
        }.navigationTitle(L10n.text("连接相机 Wi-Fi")).navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("camera.manual.page")
    }
}

private struct IOSCameraConnectionGuide: View {
    var body: some View {
        List {
            Section {
                Text(L10n.text("相机菜单会随型号和固件变化，请按机身提供的手机连接方式操作。"))
            }
            Section(L10n.text("连接前准备")) {
                Text(L10n.text("保持相机开机，在机身菜单打开智能手机连接。菜单名称以你的机型为准。关闭占用相机连接的其他应用。"))
            }
            Section(L10n.text("方式一：在系统 Wi-Fi 设置连接（推荐）")) {
                Text(L10n.text("打开相机智能手机连接，在系统「设置 → 无线局域网」加入相机显示的 Wi-Fi（无互联网属正常情况），再返回点击“已连接，继续”。"))
                Text(L10n.text("初代 ZV-E10 可使用机身“智能手机连接”中的连接画面；无需把蓝牙配对作为必经步骤。"))
            }
            Section(L10n.text("方式二：蓝牙唤醒并获取密码")) {
                Text(L10n.text("蓝牙发现相机后点击连接，可自动唤醒相机 Wi-Fi。具备 Hotspot 权限时将自动加入；个人免费签名会显示 Wi-Fi 名称和一次性复制密码，按提示在系统设置加入后返回继续。"))
            }
            Section(L10n.text("联机拍摄设置")) {
                Text(L10n.text("在相机上选择单张拍摄，并将原件同时保留在存储卡。手机收到的取景图和缩略图不是原件保存成功的凭据。"))
                Text(L10n.text("RawLab 按相机实际提供的选项显示可调参数，不会替你更改驱动模式或保存目的地。"))
            }
            Section(L10n.text("连接遇到问题")) {
                Text(L10n.text("搜索不到时，检查蓝牙权限和机身等待连接画面。Wi-Fi 无互联网是正常情况，请保持连接。"))
            }
            Section(L10n.text("未验证的机型也可以连接")) {
                Text(L10n.text("部分功能不可用时，检查相机模式。已验证型号仅作参考，其他 Sony 相机也可以尝试连接。"))
            }
        }.navigationTitle(L10n.text("如何连接")).navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("camera.help.page")
    }
}
