import SwiftUI

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
    private var previousCamera: CameraDeviceIdentity? { model.device ?? model.manifest.tether?.camera ?? model.manifest.jobs.last?.camera }
    private var cameraName: String { previousCamera?.model == "ILCE-7CM2" ? "α7C II" : previousCamera?.model ?? L10n.text("相机") }
    let onOpenOriginal: (URL) -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack(path: $path) {
            home.navigationTitle(L10n.text("相机")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(L10n.text("导入记录")) { path.append(.history) }
                            Button(L10n.text("保存位置")) { path.append(.storage) }
                        } label: { Image(systemName: "ellipsis") }.accessibilityLabel(L10n.text("更多")).accessibilityIdentifier("camera.menu")
                    }
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
            if phase == .background { connection.stop(); model.stop() }
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
                if model.manifest.tether != nil {
                    Button { choose(.tethering, resume: true) } label: {
                        Label(L10n.text("恢复上次联机"), systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.accessibilityIdentifier("camera.resume.tether")
                    Text(L10n.text("恢复未完成的原件接收，不会自动补拍。")).font(.footnote).foregroundStyle(.secondary)
                }
                Divider().padding(.vertical, 4)
                Button { path.append(.history) } label: {
                    HStack { Label(L10n.text("导入记录"), systemImage: "clock.arrow.circlepath"); Spacer(); Text("\(model.originals.count)").monospacedDigit() }
                        .frame(minHeight: 44)
                }.accessibilityIdentifier("camera.history")
                Button { path.append(.storage) } label: {
                    Label(L10n.text("保存位置"), systemImage: "folder").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
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
                    Toggle(L10n.text("已确认相机同时将原件保存到存储卡。"), isOn: $cardConfirmed)
                        .font(.callout).accessibilityIdentifier("camera.card.confirm")
                }
                if connection.connecting || model.phase == .connecting {
                    HStack { ProgressView(); Text(connection.status.isEmpty ? L10n.text("正在连接相机…") : connection.status) }
                        .font(.callout).padding(.vertical, 8)
                    Button(L10n.text("取消连接")) { connection.stop(); model.stop() }.frame(minHeight: 44)
                } else {
                    ForEach(connection.candidates) { candidate in
                        Button { connection.connect(candidate) } label: {
                            HStack {
                                Image(systemName: "camera"); Text(candidate.name).foregroundStyle(.primary)
                                Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }.padding(.horizontal, 12).frame(minHeight: 56)
                                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 8))
                        }.disabled(mode == .tethering && !cardConfirmed)
                            .accessibilityIdentifier("camera.candidate")
                    }
                    if connection.candidates.isEmpty {
                        Text(L10n.text("未发现相机。请打开相机的智能手机连接。")).font(.callout).foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    Button { connection.search() } label: {
                        HStack { if connection.searching { ProgressView() }; Label(L10n.text("查找相机"), systemImage: "arrow.clockwise") }
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered).disabled(connection.searching).accessibilityIdentifier("camera.search")
                    Button { path.append(.manual) } label: {
                        Label(L10n.text("连接相机 Wi-Fi"), systemImage: "wifi").frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered).disabled(mode == .tethering && !cardConfirmed)
                        .accessibilityIdentifier("camera.manual")
                }
                if !connection.status.isEmpty && !connection.connecting {
                    Text(connection.status).font(.footnote).foregroundStyle(.secondary)
                }
                if let error = model.manualImportRequired ? model.notice : connection.failure ?? model.notice {
                    Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("camera.connection.error")
                    if model.manualImportRequired && mode == .tethering {
                        Button(L10n.text("从相机导入")) { choose(.importing, resume: false) }
                            .frame(minHeight: 44).accessibilityIdentifier("camera.connection.manual-import")
                    } else if connection.failure != nil {
                        Button(L10n.text("系统权限设置")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }.frame(minHeight: 44)
                    }
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
                Text(L10n.text("完整原件保存在 RawLab 的持久存储中，结束联机或清理编辑缓存不会删除它们。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Text(L10n.text("从导入记录打开原件进行编辑；原始照片不会被调整覆盖。")).font(.callout)
                Button(L10n.text("导入记录")) { path.append(.history) }
            }
        }.navigationTitle(L10n.text("相机照片保存位置")).navigationBarTitleDisplayMode(.inline)
    }
    private func choose(_ value: IOSCameraMode, resume: Bool) {
        connection.stop(); model.stop()
        mode = value; resumeTether = resume; cardConfirmed = false; pendingImport = nil
        model.clearNotice(); path = [.connect]; connection.search()
    }
    private func reconnect() {
        connection.stop(); model.stop()
        mode = model.mode; resumeTether = mode == .tethering && model.manifest.tether != nil
        model.clearNotice(); path = [.connect]; connection.search()
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
            Section {
                Text(L10n.text("在相机打开智能手机连接，查看机身显示的 Wi-Fi 名称和密码。你也可以先在系统 Wi-Fi 设置中连接，再返回继续。"))
                TextField(L10n.text("Wi-Fi 名称"), text: $ssid).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("camera.wifi.ssid")
                SecureField(L10n.text("Wi-Fi 密码"), text: $password).accessibilityIdentifier("camera.wifi.password")
                Button(L10n.text("连接相机 Wi-Fi")) {
                    connection.join(ssid: ssid, password: password); password = ""
                }.disabled(ssid.isEmpty || password.count < 8 || connecting)
                    .accessibilityIdentifier("camera.wifi.join")
            }
            Section {
                Button(L10n.text("已连接，继续")) { connection.useCurrentWiFi() }
                    .disabled(connecting).accessibilityIdentifier("camera.wifi.continue")
                Text(L10n.text("相机 Wi-Fi 通常无法访问互联网，请保持连接。")).font(.footnote)
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
            if let error = model.notice ?? connection.failure { Section { Text(error).foregroundStyle(.orange) } }
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
            Section(L10n.text("使用蓝牙配对")) {
                Text(L10n.text("在连接页查找并选择相机，按手机和相机提示完成配对，再允许系统加入相机 Wi-Fi。蓝牙配对成功不等于照片连接已经建立。"))
            }
            Section(L10n.text("手动连接 Wi-Fi")) {
                Text(L10n.text("如果相机显示 SSID 和密码，打开手动连接页并填写；也可先在系统 Wi-Fi 设置中加入该网络，再返回点击“已连接，继续”。"))
                Text(L10n.text("初代 ZV-E10 可使用机身“智能手机连接”中的连接画面；无需把蓝牙配对作为必经步骤。"))
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
