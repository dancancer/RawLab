import Foundation
import Combine
import CoreBluetooth
import Network
import NetworkExtension

struct IOSCameraCandidate: Identifiable, Equatable {
    let id: UUID
    let name: String
}
struct IOSCameraEndpoint: Equatable {
    let host: String
    let connectionKey: String
    let label: String
}

@MainActor final class IOSCameraConnection: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published private(set) var candidates: [IOSCameraCandidate] = []
    @Published private(set) var searching = false
    @Published private(set) var connecting = false
    @Published private(set) var status = ""
    @Published private(set) var failure: String?
    var onEndpoint: ((IOSCameraEndpoint) -> Void)?

    private enum Stage { case idle, connecting, services, characteristics, pairing, wifiStart, ssid, password, joining, routing }
    private var stage = Stage.idle
    private var generation = UUID()
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var characteristics: [String: CBCharacteristic] = [:]
    private var pendingServices: Set<CBUUID> = []
    private var pathMonitor: NWPathMonitor?
    private var ssid: String?
    private var connectionKey = ""
    private var label = ""
    private var discoveryRequested = false
    private static let control = CBUUID(string: "8000cc00-cc00-ffff-ffff-ffffffffffff")
    private static let pairing = CBUUID(string: "8000ee00-ee00-ffff-ffff-ffffffffffff")
    private static func characteristic(_ name: String) -> CBUUID { CBUUID(string: "0000\(name)-0000-1000-8000-00805f9b34fb") }

    func search() {
        stop()
        candidates = []; peripherals = [:]; failure = nil
        discoveryRequested = true; searching = true; status = L10n.text("正在查找相机…")
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else { startScanIfReady() }
    }
    private func startScanIfReady() {
        guard discoveryRequested, let central else { return }
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            let token = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
                guard let self, self.generation == token, self.searching else { return }
                self.central?.stopScan(); self.searching = false; self.discoveryRequested = false
                if self.candidates.isEmpty { self.status = L10n.text("没有找到相机。请保持相机处于等待连接画面。") }
                else { self.status = "" }
            }
        case .unauthorized: fail(L10n.text("请在系统设置中允许 RawLab 使用蓝牙。"))
        case .poweredOff: fail(L10n.text("请打开手机蓝牙后重试。"))
        case .unsupported: fail(L10n.text("此设备不支持蓝牙连接，请手动连接相机 Wi-Fi。"))
        default: break
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        startScanIfReady()
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central, searching else { return }
        let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard manufacturer?.starts(with: [0x2d, 0x01]) == true || services.contains(Self.control) || services.contains(Self.pairing) else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Sony"
        peripherals[peripheral.identifier] = peripheral
        let candidate = IOSCameraCandidate(id: peripheral.identifier, name: name)
        if let index = candidates.firstIndex(where: { $0.id == candidate.id }) { candidates[index] = candidate }
        else { candidates.append(candidate) }
    }
    func connect(_ candidate: IOSCameraCandidate) {
        guard let selected = peripherals[candidate.id], let central, central.state == .poweredOn else {
            fail(L10n.text("请打开手机蓝牙后重试。")); return
        }
        stop()
        failure = nil; connecting = true; peripheral = selected; selected.delegate = self
        connectionKey = "BLE:" + candidate.id.uuidString; label = candidate.name
        stage = .connecting; status = L10n.text("正在连接相机…")
        central.connect(selected)
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
            guard let self, self.generation == token, self.connecting else { return }
            self.fail(L10n.text("连接未完成。请保持相机唤醒，重新查找并连接。"))
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central, peripheral === self.peripheral, stage == .connecting else { return }
        guard peripheral.maximumWriteValueLength(for: .withResponse) >= 7 else {
            fail(L10n.text("此蓝牙连接无法完成配对，请手动连接相机 Wi-Fi。")); return
        }
        stage = .services; peripheral.discoverServices([Self.control, Self.pairing])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === self.peripheral else { return }
        fail(L10n.text("连接未完成。请保持相机唤醒，重新查找并连接。"))
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === self.peripheral, connecting else { return }
        fail(L10n.text("相机连接已断开。已保存的照片仍可查看。"))
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral, stage == .services else { return }
        guard error == nil, let services = peripheral.services,
              services.contains(where: { $0.uuid == Self.control }), services.contains(where: { $0.uuid == Self.pairing }) else {
            fail(L10n.text("相机未提供此蓝牙配对方式，请使用手动 Wi-Fi 连接。")); return
        }
        stage = .characteristics; pendingServices = [Self.control, Self.pairing]
        for service in services where pendingServices.contains(service.uuid) {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral, stage == .characteristics, pendingServices.contains(service.uuid) else { return }
        guard error == nil else { fail(L10n.text("相机未提供此蓝牙配对方式，请使用手动 Wi-Fi 连接。")); return }
        for name in ["cc06", "cc07", "cc08", "ee01"] {
            if let value = service.characteristics?.first(where: { $0.uuid == Self.characteristic(name) }) { characteristics[name] = value }
        }
        pendingServices.remove(service.uuid)
        guard pendingServices.isEmpty else { return }
        guard let pairing = characteristics["ee01"], pairing.properties.contains(.write),
              let wifi = characteristics["cc08"], wifi.properties.contains(.write),
              characteristics["cc06"]?.properties.contains(.read) == true,
              characteristics["cc07"]?.properties.contains(.read) == true else {
            fail(L10n.text("相机未提供此蓝牙配对方式，请使用手动 Wi-Fi 连接。")); return
        }
        stage = .pairing; status = L10n.text("请核对手机和相机的配对数字")
        peripheral.writeValue(Data([6, 8, 1, 0, 0, 0, 0]), for: pairing, type: .withResponse)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil else { fail(L10n.text("连接未完成。请保持相机唤醒，重新查找并连接。")); return }
        if stage == .pairing, characteristic === characteristics["ee01"], let wifi = characteristics["cc08"] {
            stage = .wifiStart; status = L10n.text("正在开启相机 Wi-Fi…")
            peripheral.writeValue(Data([1]), for: wifi, type: .withResponse)
        } else if stage == .wifiStart, characteristic === characteristics["cc08"] {
            let token = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak peripheral] in
                guard let self, let peripheral, self.generation == token, peripheral === self.peripheral,
                      self.stage == .wifiStart, let ssid = self.characteristics["cc06"] else { return }
                self.stage = .ssid; peripheral.readValue(for: ssid)
            }
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil, let bytes = characteristic.value else {
            fail(L10n.text("无法读取相机 Wi-Fi 信息，请手动连接。")); return
        }
        do {
            if stage == .ssid, characteristic === characteristics["cc06"], let password = characteristics["cc07"] {
                ssid = try CameraWire.wifiCredential(bytes, password: false)
                stage = .password; peripheral.readValue(for: password)
            } else if stage == .password, characteristic === characteristics["cc07"], let ssid {
                let password = try CameraWire.wifiCredential(bytes, password: true)
                self.peripheral = nil; peripheral.delegate = nil; central?.cancelPeripheralConnection(peripheral)
                join(ssid: ssid, password: password, preserveIdentity: true)
            }
        } catch { fail(L10n.text("无法读取相机 Wi-Fi 信息，请手动连接。")) }
    }
    func join(ssid: String, password: String, preserveIdentity: Bool = false) {
        let name = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 32, (8...63).contains(password.utf8.count) else {
            failure = L10n.text("请输入相机显示的 Wi-Fi 名称和密码。"); return
        }
        if !preserveIdentity { stop(); connectionKey = "SSID:" + name; label = name }
        self.ssid = name; failure = nil; connecting = true; stage = .joining
        status = L10n.text("请允许系统连接相机 Wi-Fi")
        let configuration = NEHotspotConfiguration(ssid: name, passphrase: password, isWEP: false)
        configuration.joinOnce = true
        let token = generation
        NEHotspotConfigurationManager.shared.apply(configuration) { [weak self] error in
            Task { @MainActor in
                guard let self, self.generation == token, self.stage == .joining else { return }
                if let error, (error as NSError).code != NEHotspotConfigurationError.alreadyAssociated.rawValue {
                    self.fail(L10n.text("未能加入相机 Wi-Fi。请在系统 Wi-Fi 设置连接后返回。")); return
                }
                self.routeToCamera(token: token)
            }
        }
    }
    func useCurrentWiFi() {
        stop(); failure = nil; connecting = true; stage = .routing
        let token = generation
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if let network { self.connectionKey = "SSID:" + network.ssid; self.label = network.ssid }
                self.routeToCamera(token: token)
            }
        }
    }
    private func routeToCamera(token: UUID) {
        stage = .routing; status = L10n.text("正在连接相机…")
        pathMonitor?.cancel()
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied, path.usesInterfaceType(.wifi) else { return }
            let host = path.gateways.compactMap { endpoint -> String? in
                if case .hostPort(let host, _) = endpoint, case .ipv4(let address) = host {
                    return String(describing: address)
                }
                return nil
            }.first(where: CameraTCPChannel.localIPv4)
            guard let host else { return }
            Task { @MainActor in
                guard let self, self.generation == token, self.stage == .routing else { return }
                self.pathMonitor?.cancel(); self.pathMonitor = nil
                self.stage = .idle; self.connecting = false; self.status = ""
                let key = self.connectionKey.isEmpty ? "route:" + host : self.connectionKey
                self.onEndpoint?(IOSCameraEndpoint(host: host, connectionKey: key, label: self.label))
            }
        }
        monitor.start(queue: DispatchQueue(label: "rawlab.camera.wifi-path"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.generation == token, self.stage == .routing else { return }
            self.fail(L10n.text("请先在系统 Wi-Fi 设置连接相机，再返回继续。"))
        }
    }
    func stop() {
        generation = UUID(); discoveryRequested = false; searching = false; connecting = false
        pathMonitor?.cancel(); pathMonitor = nil; central?.stopScan()
        if let peripheral { peripheral.delegate = nil; central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil; characteristics = [:]; pendingServices = []; ssid = nil
        connectionKey = ""; label = ""; stage = .idle
    }
    private func fail(_ message: String) { stop(); failure = message; status = "" }
}
