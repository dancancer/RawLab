package com.rawlab.android.camera

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanRecord
import android.bluetooth.le.ScanResult
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.MacAddress
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiInfo
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.rawlab.android.camera.protocol.SonyWifiCredentials
import java.io.Closeable
import java.net.Inet4Address
import java.net.InetAddress
import java.util.LinkedHashMap
import java.util.UUID

internal data class CameraCandidate(val id: String, val name: String)

/** 只管理 Android BLE/Wi-Fi 连接；PTP、凭据持久化、进程绑网和解绑不在此处。 */
internal class SonyCameraConnection(
    context: Context,
    private val listener: Listener,
) : Closeable {
    interface Listener {
        fun onCandidates(items: List<CameraCandidate>)
        fun onStage(stage: Stage)
        /** 上层用返回 Network 的 socketFactory 连接相机 TCP 15740。 */
        fun onConnected(network: Network, address: InetAddress, cameraId: String)
        fun onFailure(reason: Failure)
    }

    enum class Stage { SCANNING, PAIRING, BLUETOOTH, WIFI_STARTING, WIFI_CONFIRMATION, MANUAL_WIFI, NETWORK }

    enum class Failure {
        UNSUPPORTED,
        PERMISSION,
        BLUETOOTH_OFF,
        LOCATION_OFF,
        NOT_FOUND,
        PAIRING,
        BLUETOOTH,
        WIFI,
        DISCONNECTED,
    }

    private companion object {
        const val SONY_MANUFACTURER_ID = 0x012d
        const val SONY_CAMERA_LABEL = "Sony camera"
        const val BLE_MTU = 158
        const val BLE_TIMEOUT_MS = 3 * 60 * 1000L
        const val BLE_SCAN_TIMEOUT_MS = 25 * 1000L
        const val WIFI_SCAN_TIMEOUT_MS = 35 * 1000L
        const val WIFI_FRESHNESS_US = 2_000_000L

        val CONTROL_SERVICE = UUID.fromString("8000cc00-cc00-ffff-ffff-ffffffffffff")
        val PAIRING_SERVICE = UUID.fromString("8000ee00-ee00-ffff-ffff-ffffffffffff")

        fun sonyCharacteristic(suffix: String): UUID =
            UUID.fromString("0000${suffix.lowercase()}-0000-1000-8000-00805f9b34fb")

        val SSID_CHARACTERISTIC = sonyCharacteristic("cc06")
        val PASSWORD_CHARACTERISTIC = sonyCharacteristic("cc07")
        val WIFI_ON_CHARACTERISTIC = sonyCharacteristic("cc08")
        val PAIRING_INIT_CHARACTERISTIC = sonyCharacteristic("ee01")
    }

    private val appContext = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val bluetoothManager = appContext.getSystemService(BluetoothManager::class.java)
    private val connectivity = appContext.getSystemService(ConnectivityManager::class.java)
    private val wifi = appContext.getSystemService(WifiManager::class.java)
    private val location = appContext.getSystemService(LocationManager::class.java)

    private var adapter: BluetoothAdapter? = bluetoothManager?.adapter
    private var scanner: BluetoothLeScanner? = null
    private var scannerCallback: ScanCallback? = null
    private var gatt: BluetoothGatt? = null
    private var selectedDevice: BluetoothDevice? = null
    private var selectedId: String? = null

    private val devices = LinkedHashMap<String, BluetoothDevice>()
    private val deviceNames = LinkedHashMap<String, String>()
    private var scanning = false
    private var active = false
    @Volatile private var generation = 0L
    private var stage: Stage? = null
    private var readAttempts = 0
    private var scanStartedMicros = 0L
    private var pendingSSID: String? = null
    private var pendingPassword: String? = null

    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var cameraNetwork: Network? = null
    private var cameraAddress: InetAddress? = null

    private var bondReceiverRegistered = false
    private var wifiReceiverRegistered = false
    private var bondReceiverGeneration = 0L
    private var wifiReceiverGeneration = 0L
    private var bleTimeout: Runnable? = null
    private var bleScanTimeout: Runnable? = null
    private var wifiScanTimeout: Runnable? = null

    private val bondReceiver = object : BroadcastReceiver() {
        @Suppress("DEPRECATION")
        override fun onReceive(context: Context, intent: Intent) {
            val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
            if (!active || bondReceiverGeneration != generation || device == null) return
            val selectedAddress = try { selectedDevice?.address } catch (_: SecurityException) {
                fail(Failure.PERMISSION)
                return
            }
            val deviceAddress = try { device.address } catch (_: SecurityException) {
                fail(Failure.PERMISSION)
                return
            }
            if (selectedAddress != deviceAddress) return
            val bondState = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.BOND_NONE)
            when (bondState) {
                BluetoothDevice.BOND_BONDED -> {
                    unregisterBondReceiver()
                    setStage(Stage.BLUETOOTH)
                    openGatt()
                }
                BluetoothDevice.BOND_NONE -> fail(Failure.PAIRING)
            }
        }
    }

    private val wifiScanReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == WifiManager.SCAN_RESULTS_AVAILABLE_ACTION &&
                wifiReceiverGeneration == generation) findFreshAccessPoint()
        }
    }

    private fun createScanCallback(current: Long): ScanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            main.post { handleScanResult(current, result) }
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>) {
            main.post { results.forEach { handleScanResult(current, it) } }
        }

        override fun onScanFailed(errorCode: Int) {
            main.post {
                if (current == generation && active && scanning) fail(Failure.BLUETOOTH)
            }
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(source: BluetoothGatt, status: Int, newState: Int) {
            main.post {
                if (!isCurrentGatt(source)) return@post
                if (status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED) {
                    val requested = try {
                        source.requestMtu(BLE_MTU)
                    } catch (_: SecurityException) {
                        fail(Failure.PERMISSION)
                        return@post
                    }
                    if (!requested) fail(Failure.BLUETOOTH)
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    fail(Failure.BLUETOOTH)
                } else if (status != BluetoothGatt.GATT_SUCCESS) {
                    fail(Failure.BLUETOOTH)
                }
            }
        }

        override fun onMtuChanged(source: BluetoothGatt, mtu: Int, status: Int) {
            main.post {
                if (!isCurrentGatt(source)) return@post
                if (status != BluetoothGatt.GATT_SUCCESS || mtu < 67) {
                    fail(Failure.BLUETOOTH)
                    return@post
                }
                val discovered = try {
                    source.discoverServices()
                } catch (_: SecurityException) {
                    fail(Failure.PERMISSION)
                    return@post
                }
                if (!discovered) fail(Failure.BLUETOOTH)
            }
        }

        override fun onServicesDiscovered(source: BluetoothGatt, status: Int) {
            main.post {
                if (!isCurrentGatt(source)) return@post
                val command = characteristic(source, CONTROL_SERVICE, WIFI_ON_CHARACTERISTIC)
                val ssid = characteristic(source, CONTROL_SERVICE, SSID_CHARACTERISTIC)
                val password = characteristic(source, CONTROL_SERVICE, PASSWORD_CHARACTERISTIC)
                val pairing = characteristic(source, PAIRING_SERVICE, PAIRING_INIT_CHARACTERISTIC)
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    fail(Failure.BLUETOOTH)
                    return@post
                }
                if (command == null || ssid == null || password == null || pairing == null ||
                    command.properties and BluetoothGattCharacteristic.PROPERTY_WRITE == 0 ||
                    pairing.properties and BluetoothGattCharacteristic.PROPERTY_WRITE == 0 ||
                    ssid.properties and BluetoothGattCharacteristic.PROPERTY_READ == 0 ||
                    password.properties and BluetoothGattCharacteristic.PROPERTY_READ == 0) {
                    beginOperation()
                    setStage(Stage.MANUAL_WIFI)
                    return@post
                }
                pairing.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                pairing.value = byteArrayOf(6, 8, 1, 0, 0, 0, 0)
                val wrote = try {
                    source.writeCharacteristic(pairing)
                } catch (_: SecurityException) {
                    fail(Failure.PERMISSION)
                    return@post
                }
                if (!wrote) fail(Failure.BLUETOOTH)
            }
        }

        override fun onCharacteristicWrite(
            source: BluetoothGatt,
            item: BluetoothGattCharacteristic,
            status: Int,
        ) {
            main.post {
                if (!isCurrentGatt(source)) return@post
                when (item.uuid) {
                    PAIRING_INIT_CHARACTERISTIC -> {
                        if (status != BluetoothGatt.GATT_SUCCESS) fail(Failure.PAIRING) else activateWifi(source)
                    }
                    WIFI_ON_CHARACTERISTIC -> {
                        if (status != BluetoothGatt.GATT_SUCCESS) fail(Failure.WIFI) else {
                            readAttempts = 0
                            scheduleSSIDRead(source)
                        }
                    }
                }
            }
        }

        override fun onCharacteristicRead(
            source: BluetoothGatt,
            item: BluetoothGattCharacteristic,
            status: Int,
        ) {
            val value = item.value?.clone()
            val key = item.uuid
            main.post { handleCharacteristicRead(source, key, value, status) }
        }
    }

    fun scan() {
        main.post { scanOnMain() }
    }

    fun connect(id: String) {
        main.post { connectOnMain(id) }
    }

    fun prepareLegacyWifi() {
        main.post { beginOperation(); setStage(Stage.MANUAL_WIFI) }
    }

    /** 手动连接当前 Wi-Fi，以协议握手确认相机能力，不根据 SSID 推断机型。 */
    fun useLegacyWifi() {
        main.post {
            beginOperation()
            if (!isSupported()) return@post fail(Failure.UNSUPPORTED)
            if (!hasPermissions(cameraWifiPermissions(Build.VERSION.SDK_INT))) return@post fail(Failure.PERMISSION)
            if (location?.isLocationEnabled != true) return@post fail(Failure.LOCATION_OFF)
            val manager = connectivity ?: return@post fail(Failure.WIFI)
            val current = generation
            class ManualWifiCallback : ConnectivityManager.NetworkCallback {
                constructor() : super()
                @androidx.annotation.RequiresApi(Build.VERSION_CODES.S)
                constructor(flags: Int) : super(flags)

                private val capabilitiesByNetwork = mutableMapOf<Network, NetworkCapabilities>()
                private val propertiesByNetwork = mutableMapOf<Network, LinkProperties>()

                private fun inspect(network: Network) {
                    val capabilities = capabilitiesByNetwork[network] ?: return
                    val properties = propertiesByNetwork[network] ?: return
                    inspectLegacyNetwork(network, capabilities, properties, current, this)
                }

                override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                    main.post {
                        if (!isCurrentNetwork(current, this)) return@post
                        capabilitiesByNetwork[network] = capabilities
                        inspect(network)
                    }
                }
                override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
                    main.post {
                        if (!isCurrentNetwork(current, this)) return@post
                        propertiesByNetwork[network] = properties
                        inspect(network)
                    }
                }
                override fun onLost(network: Network) { main.post {
                    if (!isCurrentNetwork(current, this)) return@post
                    capabilitiesByNetwork.remove(network)
                    propertiesByNetwork.remove(network)
                    if (network == cameraNetwork) fail(Failure.DISCONNECTED)
                } }
            }
            val callback = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                ManualWifiCallback(ConnectivityManager.NetworkCallback.FLAG_INCLUDE_LOCATION_INFO)
            else ManualWifiCallback()
            networkCallback = callback
            setStage(Stage.MANUAL_WIFI)
            try {
                manager.registerNetworkCallback(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                    .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build(), callback)
            } catch (_: SecurityException) { fail(Failure.PERMISSION) }
        }
    }

    @Suppress("DEPRECATION")
    private fun inspectLegacyNetwork(network: Network, capabilities: NetworkCapabilities, properties: LinkProperties,
        current: Long, callback: ConnectivityManager.NetworkCallback) {
        if (Build.VERSION.SDK_INT < 29 || !isCurrentNetwork(current, callback) || cameraNetwork != null) return
        if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return
        val info = capabilities.transportInfo as? WifiInfo
        var identity = SonyCameraModel.networkIdentity(info?.ssid, info?.bssid)
        // 旧系统没有位置回调标志；新系统只信任对应 Network 的回调，避免套用另一条 Wi-Fi 的身份。
        if (identity == null && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            val legacy = wifi?.connectionInfo
            identity = SonyCameraModel.networkIdentity(legacy?.ssid, legacy?.bssid)
        }
        selectedId = identity ?: return
        inspectNetwork(network, properties, callback)
    }

    /** 释放当前 BLE/Wi-Fi 资源，但保留 Android 系统配对关系。 */
    override fun close() {
        val release = {
            generation++
            active = false
            releaseResources()
        }
        if (Looper.myLooper() == Looper.getMainLooper()) release() else main.post(release)
    }

    private fun scanOnMain() {
        beginOperation()
        if (!isSupported()) return fail(Failure.UNSUPPORTED)
        if (!hasPermissions(cameraBluetoothPermissions(Build.VERSION.SDK_INT))) return fail(Failure.PERMISSION)
        val bluetooth = adapter ?: return fail(Failure.UNSUPPORTED)
        val bluetoothEnabled = try { bluetooth.isEnabled } catch (_: SecurityException) {
            fail(Failure.PERMISSION)
            return
        }
        if (!bluetoothEnabled) return fail(Failure.BLUETOOTH_OFF)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S && location?.isLocationEnabled != true)
            return fail(Failure.LOCATION_OFF)

        devices.clear()
        deviceNames.clear()
        scanning = true
        setStage(Stage.SCANNING)
        emitCandidates()
        if (!active) return
        try {
            scanner = bluetooth.bluetoothLeScanner ?: return fail(Failure.BLUETOOTH)
            val callback = createScanCallback(generation)
            scannerCallback = callback
            scanner?.startScan(callback)
        } catch (_: SecurityException) {
            fail(Failure.PERMISSION)
            return
        }
        val current = generation
        bleScanTimeout = Runnable {
            if (current != generation || !active || !scanning) return@Runnable
            scanning = false
            stopBleScan()
            if (devices.isEmpty()) fail(Failure.NOT_FOUND)
        }.also { main.postDelayed(it, BLE_SCAN_TIMEOUT_MS) }
    }

    private fun connectOnMain(id: String) {
        beginOperation()
        if (!isSupported()) return fail(Failure.UNSUPPORTED)
        val sdk = Build.VERSION.SDK_INT
        if (!hasPermissions(cameraBluetoothPermissions(sdk) + cameraWifiPermissions(sdk))) return fail(Failure.PERMISSION)
        val bluetooth = adapter ?: return fail(Failure.UNSUPPORTED)
        val bluetoothEnabled = try { bluetooth.isEnabled } catch (_: SecurityException) {
            fail(Failure.PERMISSION)
            return
        }
        if (!bluetoothEnabled) return fail(Failure.BLUETOOTH_OFF)
        if (location?.isLocationEnabled != true) return fail(Failure.LOCATION_OFF)

        val selected = devices.entries.firstOrNull { it.key.equals(id, ignoreCase = true) }?.value
            ?: return fail(Failure.NOT_FOUND)
        selectedDevice = selected
        selectedId = try { selected.address } catch (_: SecurityException) {
            fail(Failure.PERMISSION)
            return
        }
        scanning = false
        stopBleScan()
        val bonded = try {
            selected.bondState == BluetoothDevice.BOND_BONDED
        } catch (_: SecurityException) {
            fail(Failure.PERMISSION)
            return
        }
        setStage(if (bonded) Stage.BLUETOOTH else Stage.PAIRING)
        if (!active) return
        startBleTimeout()
        try {
            if (bonded) {
                openGatt()
            } else {
                if (registerBondReceiver() && active && !selected.createBond()) fail(Failure.PAIRING)
            }
        } catch (_: SecurityException) {
            fail(Failure.PERMISSION)
        }
    }

    private fun beginOperation() {
        generation++
        active = false
        releaseResources()
        active = true
    }

    private fun isSupported(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    private fun hasPermissions(permissions: List<String>): Boolean =
        permissions.all { appContext.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    private fun handleScanResult(current: Long, result: ScanResult) {
        if (current != generation || !active || !scanning) return
        val record: ScanRecord = result.scanRecord ?: return
        val services = record.serviceUuids.orEmpty().map { it.uuid }
        if (record.getManufacturerSpecificData(SONY_MANUFACTURER_ID) == null &&
            CONTROL_SERVICE !in services && PAIRING_SERVICE !in services) return
        val name = record.deviceName?.takeIf { it.isNotBlank() } ?: SONY_CAMERA_LABEL
        val device = try { result.device } catch (_: SecurityException) {
            fail(Failure.PERMISSION)
            return
        }
        val id = try { device.address } catch (_: SecurityException) {
            fail(Failure.PERMISSION)
            return
        }
        if (devices.putIfAbsent(id, device) == null) {
            deviceNames[id] = name
            emitCandidates()
        }
    }

    private fun emitCandidates() {
        listener.onCandidates(devices.map { CameraCandidate(it.key, deviceNames[it.key] ?: it.value.nameOrFallback()) })
    }

    private fun BluetoothDevice.nameOrFallback(): String = try {
        name?.takeIf { it.isNotBlank() } ?: SONY_CAMERA_LABEL
    } catch (_: SecurityException) {
        SONY_CAMERA_LABEL
    }

    private fun openGatt() {
        val device = selectedDevice ?: return fail(Failure.BLUETOOTH)
        setStage(Stage.BLUETOOTH)
        if (!active) return
        try {
            gatt = device.connectGatt(appContext, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            if (gatt == null) fail(Failure.BLUETOOTH)
        } catch (_: SecurityException) {
            fail(Failure.PERMISSION)
        }
    }

    private fun characteristic(
        source: BluetoothGatt,
        serviceUuid: UUID,
        characteristicUuid: UUID,
    ): BluetoothGattCharacteristic? = source.getService(serviceUuid)?.getCharacteristic(characteristicUuid)

    private fun isCurrentGatt(source: BluetoothGatt): Boolean {
        if (!active || source !== gatt) return false
        val selectedAddress = try { selectedDevice?.address } catch (_: SecurityException) { return false }
        val sourceAddress = try { source.device.address } catch (_: SecurityException) { return false }
        return selectedAddress == sourceAddress
    }

    private fun activateWifi(source: BluetoothGatt) {
        val command = characteristic(source, CONTROL_SERVICE, WIFI_ON_CHARACTERISTIC)
            ?: return fail(Failure.WIFI)
        setStage(Stage.WIFI_STARTING)
        if (!active) return
        command.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        command.value = byteArrayOf(1)
        val wrote = try {
            source.writeCharacteristic(command)
        } catch (_: SecurityException) {
            fail(Failure.PERMISSION)
            return
        }
        if (!wrote) fail(Failure.WIFI)
    }

    private fun scheduleSSIDRead(source: BluetoothGatt) {
        val current = generation
        main.postDelayed({
            if (current != generation || !isCurrentGatt(source)) return@postDelayed
            readAttempts++
            val characteristic = characteristic(source, CONTROL_SERVICE, SSID_CHARACTERISTIC)
            val read = try {
                characteristic != null && source.readCharacteristic(characteristic)
            } catch (_: SecurityException) {
                fail(Failure.PERMISSION)
                return@postDelayed
            }
            if (!read) fail(Failure.WIFI)
        }, 3_000L)
    }

    private fun handleCharacteristicRead(
        source: BluetoothGatt,
        key: UUID,
        value: ByteArray?,
        status: Int,
    ) {
        if (!isCurrentGatt(source)) return
        if (status != BluetoothGatt.GATT_SUCCESS) {
            if (key == SSID_CHARACTERISTIC && status == 157 && readAttempts < 8) {
                scheduleSSIDRead(source)
            } else {
                fail(Failure.WIFI)
            }
            return
        }
        try {
            when (key) {
                SSID_CHARACTERISTIC -> {
                    pendingSSID = SonyWifiCredentials.decode(value, false)
                    val password = characteristic(source, CONTROL_SERVICE, PASSWORD_CHARACTERISTIC)
                    val read = try {
                        password != null && source.readCharacteristic(password)
                    } catch (_: SecurityException) {
                        fail(Failure.PERMISSION)
                        return
                    }
                    if (!read) fail(Failure.WIFI)
                }
                PASSWORD_CHARACTERISTIC -> {
                    val ssid = pendingSSID ?: return fail(Failure.WIFI)
                    pendingPassword = SonyWifiCredentials.decode(value, true)
                    waitForAccessPoint(ssid)
                }
            }
        } catch (_: IllegalArgumentException) {
            fail(Failure.WIFI)
        }
    }

    private fun waitForAccessPoint(name: String) {
        if (pendingPassword == null || wifi == null) return fail(Failure.WIFI)
        if (!active) return
        cancelBleTimeout()
        scanStartedMicros = SystemClock.elapsedRealtimeNanos() / 1_000L
        pendingSSID = name
        if (!registerWifiReceiver() || !active) return
        try {
            wifi.startScan()
            findFreshAccessPoint()
        } catch (_: SecurityException) {
            fail(Failure.PERMISSION)
            return
        }
        if (!active || pendingSSID == null) return
        val current = generation
        wifiScanTimeout = Runnable {
            if (current == generation && active && pendingSSID != null) fail(Failure.WIFI)
        }.also { main.postDelayed(it, WIFI_SCAN_TIMEOUT_MS) }
    }

    private fun findFreshAccessPoint() {
        val name = pendingSSID ?: return
        if (!active || generation <= 0L || wifi == null) return
        val results = try { wifi.scanResults } catch (_: SecurityException) {
            fail(Failure.PERMISSION)
            return
        }
        for (result in results) {
            val bssid = result.BSSID ?: continue
            if (result.SSID == name && result.timestamp >= scanStartedMicros - WIFI_FRESHNESS_US) {
                requestWiFi(name, pendingPassword ?: return fail(Failure.WIFI), bssid)
                return
            }
        }
    }

    private fun requestWiFi(name: String, password: String, bssid: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            fail(Failure.UNSUPPORTED)
            return
        }
        unregisterWifiReceiver()
        pendingSSID = null
        pendingPassword = null
        cancelWifiScanTimeout()
        val manager = connectivity ?: return fail(Failure.WIFI)
        val current = generation
        val specifier = try {
            WifiNetworkSpecifier.Builder()
                .setSsid(name)
                .setBssid(MacAddress.fromString(bssid))
                .setWpa2Passphrase(password)
                .build()
        } catch (_: IllegalArgumentException) {
            fail(Failure.WIFI)
            return
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()
        lateinit var callback: ConnectivityManager.NetworkCallback
        callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val source = this
                main.post {
                    if (!isCurrentNetwork(current, source)) return@post
                    inspectNetwork(network, manager.getLinkProperties(network), source)
                }
            }

            override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
                val source = this
                main.post {
                    if (!isCurrentNetwork(current, source)) return@post
                    inspectNetwork(network, properties, source)
                }
            }

            override fun onUnavailable() {
                val source = this
                main.post {
                    if (isCurrentNetwork(current, source)) fail(Failure.WIFI)
                }
            }

            override fun onLost(network: Network) {
                val source = this
                main.post {
                    if (isCurrentNetwork(current, source)) fail(Failure.DISCONNECTED)
                }
            }
        }
        networkCallback = callback
        setStage(Stage.WIFI_CONFIRMATION)
        if (!active) return
        try {
            manager.requestNetwork(request, callback)
        } catch (_: SecurityException) {
            fail(Failure.PERMISSION)
        } catch (_: IllegalArgumentException) {
            fail(Failure.WIFI)
        }
    }

    private fun isCurrentNetwork(current: Long, callback: ConnectivityManager.NetworkCallback): Boolean =
        active && current == generation && networkCallback === callback

    private fun inspectNetwork(
        network: Network,
        properties: LinkProperties?,
        callback: ConnectivityManager.NetworkCallback,
    ) {
        if (networkCallback !== callback || cameraNetwork != null) return
        val routes = properties?.routes ?: return
        val gateway = routes.asSequence()
            .filter { it.isDefaultRoute }
            .mapNotNull { it.gateway as? Inet4Address }
            .firstOrNull() ?: return
        cameraNetwork = network
        cameraAddress = gateway
        cancelBleTimeout()
        val cameraId = selectedId ?: return
        setStage(Stage.NETWORK)
        if (!active) return
        listener.onConnected(network, gateway, cameraId)
    }

    private fun setStage(value: Stage) {
        if (stage == value) return
        stage = value
        listener.onStage(value)
    }

    private fun startBleTimeout() {
        cancelBleTimeout()
        val current = generation
        bleTimeout = Runnable {
            if (current != generation || !active) return@Runnable
            when (stage) {
                Stage.PAIRING -> fail(Failure.PAIRING)
                Stage.BLUETOOTH -> fail(Failure.BLUETOOTH)
                else -> Unit
            }
        }.also { main.postDelayed(it, BLE_TIMEOUT_MS) }
    }

    private fun cancelBleTimeout() {
        bleTimeout?.let(main::removeCallbacks)
        bleTimeout = null
    }

    private fun cancelWifiScanTimeout() {
        wifiScanTimeout?.let(main::removeCallbacks)
        wifiScanTimeout = null
    }

    private fun fail(reason: Failure) {
        if (!active) return
        active = false
        releaseResources()
        listener.onFailure(reason)
    }

    private fun releaseResources() {
        scanning = false
        bleScanTimeout?.let(main::removeCallbacks)
        bleScanTimeout = null
        cancelBleTimeout()
        cancelWifiScanTimeout()
        stopBleScan()
        unregisterBondReceiver()
        unregisterWifiReceiver()
        pendingSSID = null
        pendingPassword = null
        selectedDevice = null
        selectedId = null
        stage = null
        cameraNetwork = null
        cameraAddress = null
        val callback = networkCallback
        networkCallback = null
        if (callback != null) {
            try { connectivity?.unregisterNetworkCallback(callback) } catch (_: Exception) { }
        }
        val oldGatt = gatt
        gatt = null
        if (oldGatt != null) {
            try { oldGatt.disconnect() } catch (_: SecurityException) { }
            try { oldGatt.close() } catch (_: SecurityException) { }
        }
    }

    private fun stopBleScan() {
        val currentScanner = scanner ?: return
        val callback = scannerCallback
        scanner = null
        scannerCallback = null
        if (callback != null) {
            try { currentScanner.stopScan(callback) } catch (_: SecurityException) { }
        }
    }

    private fun registerBondReceiver(): Boolean {
        if (bondReceiverRegistered) return true
        try {
            val filter = IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                appContext.registerReceiver(bondReceiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                appContext.registerReceiver(bondReceiver, filter)
            }
            bondReceiverRegistered = true
            bondReceiverGeneration = generation
            return true
        } catch (_: Exception) {
            fail(Failure.PAIRING)
            return false
        }
    }

    private fun unregisterBondReceiver() {
        if (!bondReceiverRegistered) return
        try { appContext.unregisterReceiver(bondReceiver) } catch (_: Exception) { }
        bondReceiverRegistered = false
        bondReceiverGeneration = 0L
    }

    private fun registerWifiReceiver(): Boolean {
        if (wifiReceiverRegistered) return true
        try {
            val filter = IntentFilter(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                appContext.registerReceiver(wifiScanReceiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                appContext.registerReceiver(wifiScanReceiver, filter)
            }
            wifiReceiverRegistered = true
            wifiReceiverGeneration = generation
            return true
        } catch (_: Exception) {
            fail(Failure.WIFI)
            return false
        }
    }

    private fun unregisterWifiReceiver() {
        if (!wifiReceiverRegistered) return
        try { appContext.unregisterReceiver(wifiScanReceiver) } catch (_: Exception) { }
        wifiReceiverRegistered = false
        wifiReceiverGeneration = 0L
    }
}
