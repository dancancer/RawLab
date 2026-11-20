package com.rawlab.android.camera

import android.annotation.SuppressLint
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
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
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
internal class SonyCameraConnection internal constructor(
    context: Context,
    private val listener: Listener,
    private val platform: Platform,
    private val wifiStartingTimeoutMs: Long = WIFI_STARTING_TIMEOUT_MS,
    private val wifiRequestTimeoutMs: Long = WIFI_REQUEST_TIMEOUT_MS,
) : Closeable {
    constructor(context: Context, listener: Listener) : this(
        context,
        listener,
        AndroidPlatform(context.applicationContext),
    )

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

    internal data class BleScanEntry(
        val id: String,
        val name: String,
        val isSony: Boolean,
        val isBonded: Boolean,
        val connectGatt: (GattClientCallback) -> GattHandle?,
        val createBond: () -> Boolean,
    )

    internal data class WifiApResult(val ssid: String?, val bssid: String?, val timestampMicros: Long)

    internal interface Handle {
        fun close()
    }

    internal interface GattHandle {
        val address: String?
        fun requestMtu(mtu: Int): Boolean
        fun discoverServices(): Boolean
        fun hasRequiredCharacteristics(): Boolean
        fun hasWifiOnCharacteristic(): Boolean
        fun writePairingInit(): Boolean
        fun writeWifiOn(): Boolean
        fun readSsid(): Boolean
        fun readPassword(): Boolean
        fun disconnect()
        fun close()
    }

    internal interface GattClientCallback {
        fun onConnectionStateChange(source: GattHandle, status: Int, newState: Int)
        fun onMtuChanged(source: GattHandle, mtu: Int, status: Int)
        fun onServicesDiscovered(source: GattHandle, status: Int)
        fun onCharacteristicWrite(source: GattHandle, uuid: UUID, status: Int)
        fun onCharacteristicRead(source: GattHandle, uuid: UUID, value: ByteArray?, status: Int)
    }

    internal interface WifiNetworkCallbacks {
        fun onAvailable(network: Network, properties: LinkProperties?)
        fun onLinkPropertiesChanged(network: Network, properties: LinkProperties)
        fun onUnavailable()
        fun onLost(network: Network)
    }

    internal interface LegacyWifiCallbacks {
        fun onLegacyNetworkReady(network: Network, identity: String, properties: LinkProperties)
        fun onLost(network: Network)
    }

    internal interface Platform {
        val sdkInt: Int
        fun isMainThread(): Boolean
        fun post(action: Runnable)
        fun postDelayed(action: Runnable, delayMs: Long)
        fun removeCallbacks(action: Runnable)
        fun elapsedMicros(): Long
        fun hasPermissions(permissions: List<String>): Boolean
        fun isBluetoothPresent(): Boolean
        fun isBluetoothEnabled(): Boolean
        fun isLocationEnabled(): Boolean
        fun startBleScan(onEntry: (BleScanEntry) -> Unit, onFailed: (Int) -> Unit): Handle?
        fun registerBondReceiver(onBondChanged: (address: String, bondState: Int) -> Unit): Handle
        fun isWifiAvailable(): Boolean
        fun startWifiScan(): Boolean
        fun wifiScanResults(): List<WifiApResult>
        fun registerWifiScanReceiver(onScanResults: () -> Unit): Handle
        fun isConnectivityAvailable(): Boolean
        fun requestWifiNetwork(ssid: String, password: String, bssid: String, callbacks: WifiNetworkCallbacks): Handle
        fun registerManualWifiNetwork(callbacks: LegacyWifiCallbacks): Handle
        fun defaultIpv4Gateway(properties: LinkProperties?): Inet4Address? =
            properties?.routes?.asSequence()
                ?.filter { it.isDefaultRoute }
                ?.mapNotNull { it.gateway as? Inet4Address }
                ?.firstOrNull()
    }

    private companion object {
        const val SONY_MANUFACTURER_ID = 0x012d
        const val SONY_CAMERA_LABEL = "Sony camera"
        const val BLE_MTU = 158
        const val BLE_TIMEOUT_MS = 3 * 60 * 1000L
        const val WIFI_STARTING_TIMEOUT_MS = 45 * 1000L
        const val WIFI_REQUEST_TIMEOUT_MS = 60 * 1000L
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

    private var scanHandle: Handle? = null
    private var gatt: GattHandle? = null
    private var selectedDevice: BleScanEntry? = null
    private var selectedId: String? = null

    private val devices = LinkedHashMap<String, BleScanEntry>()
    private val deviceNames = LinkedHashMap<String, String>()
    private var scanning = false
    private var active = false
    @Volatile private var generation = 0L
    private var stage: Stage? = null
    private var wifiCredentialsReady = false
    private var readAttempts = 0
    private var scanStartedMicros = 0L
    private var pendingSSID: String? = null
    private var pendingPassword: String? = null

    private var networkHandle: Handle? = null
    private var cameraNetwork: Network? = null
    private var cameraAddress: InetAddress? = null

    private var bondReceiverHandle: Handle? = null
    private var wifiReceiverHandle: Handle? = null
    private var bleTimeout: Runnable? = null
    private var bleScanTimeout: Runnable? = null
    private var wifiScanTimeout: Runnable? = null
    private var wifiRequestTimeout: Runnable? = null
    private var ssidReadRunnable: Runnable? = null

    private val gattCallback = object : GattClientCallback {
        override fun onConnectionStateChange(source: GattHandle, status: Int, newState: Int) {
            platform.post {
                if (!isCurrentGatt(source)) return@post
                if (status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED) {
                    val requested = try {
                        source.requestMtu(BLE_MTU)
                    } catch (_: SecurityException) {
                        fail(Failure.PERMISSION)
                        return@post
                    }
                    if (!requested) fail(Failure.BLUETOOTH)
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) {
                    if (stage == Stage.BLUETOOTH || (stage == Stage.WIFI_STARTING && !wifiCredentialsReady)) {
                        fail(Failure.BLUETOOTH)
                    }
                }
            }
        }

        override fun onMtuChanged(source: GattHandle, mtu: Int, status: Int) {
            platform.post {
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

        override fun onServicesDiscovered(source: GattHandle, status: Int) {
            platform.post {
                if (!isCurrentGatt(source)) return@post
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    fail(Failure.BLUETOOTH)
                    return@post
                }
                if (!source.hasRequiredCharacteristics()) {
                    beginOperation()
                    setStage(Stage.MANUAL_WIFI)
                    return@post
                }
                val wrote = try {
                    source.writePairingInit()
                } catch (_: SecurityException) {
                    fail(Failure.PERMISSION)
                    return@post
                }
                if (!wrote) fail(Failure.BLUETOOTH)
            }
        }

        override fun onCharacteristicWrite(source: GattHandle, uuid: UUID, status: Int) {
            platform.post {
                if (!isCurrentGatt(source)) return@post
                when (uuid) {
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

        override fun onCharacteristicRead(source: GattHandle, uuid: UUID, value: ByteArray?, status: Int) {
            val copy = value?.clone()
            platform.post { handleCharacteristicRead(source, uuid, copy, status) }
        }
    }

    fun scan() {
        platform.post { scanOnMain() }
    }

    fun connect(id: String) {
        platform.post { connectOnMain(id) }
    }

    fun prepareLegacyWifi() {
        platform.post { beginOperation(); setStage(Stage.MANUAL_WIFI) }
    }

    /** 手动连接当前 Wi-Fi，以协议握手确认相机能力，不根据 SSID 推断机型。 */
    fun useLegacyWifi() {
        platform.post {
            beginOperation()
            if (!isSupported()) return@post fail(Failure.UNSUPPORTED)
            if (!platform.hasPermissions(cameraWifiPermissions(platform.sdkInt))) return@post fail(Failure.PERMISSION)
            if (!platform.isLocationEnabled()) return@post fail(Failure.LOCATION_OFF)
            if (!platform.isConnectivityAvailable()) return@post fail(Failure.WIFI)
            val current = generation
            lateinit var handle: Handle
            val callbacks = object : LegacyWifiCallbacks {
                override fun onLegacyNetworkReady(network: Network, identity: String, properties: LinkProperties) {
                    platform.post {
                        if (!isCurrentNetwork(current, handle) || cameraNetwork != null) return@post
                        selectedId = identity
                        inspectNetwork(network, properties, handle)
                    }
                }

                override fun onLost(network: Network) {
                    platform.post {
                        if (isCurrentNetwork(current, handle) && network == cameraNetwork) {
                            fail(Failure.DISCONNECTED)
                        }
                    }
                }
            }
            setStage(Stage.MANUAL_WIFI)
            try {
                handle = platform.registerManualWifiNetwork(callbacks)
                networkHandle = handle
            } catch (_: SecurityException) {
                fail(Failure.PERMISSION)
            }
        }
    }

    /** 释放当前 BLE/Wi-Fi 资源，但保留 Android 系统配对关系。 */
    override fun close() {
        val release = {
            generation++
            active = false
            releaseResources()
        }
        if (platform.isMainThread()) release() else platform.post(release)
    }

    private fun scanOnMain() {
        beginOperation()
        if (!isSupported()) return fail(Failure.UNSUPPORTED)
        if (!platform.hasPermissions(cameraBluetoothPermissions(platform.sdkInt))) return fail(Failure.PERMISSION)
        if (!platform.isBluetoothPresent()) return fail(Failure.UNSUPPORTED)
        val bluetoothEnabled = try { platform.isBluetoothEnabled() } catch (_: SecurityException) {
            fail(Failure.PERMISSION)
            return
        }
        if (!bluetoothEnabled) return fail(Failure.BLUETOOTH_OFF)
        if (platform.sdkInt < Build.VERSION_CODES.S && !platform.isLocationEnabled()) {
            return fail(Failure.LOCATION_OFF)
        }

        devices.clear()
        deviceNames.clear()
        scanning = true
        setStage(Stage.SCANNING)
        emitCandidates()
        if (!active) return
        val current = generation
        try {
            val handle = platform.startBleScan(
                onEntry = { entry -> platform.post { handleScanResult(current, entry) } },
                onFailed = { platform.post { if (current == generation && active && scanning) fail(Failure.BLUETOOTH) } },
            ) ?: return fail(Failure.BLUETOOTH)
            scanHandle = handle
        } catch (_: SecurityException) {
            fail(Failure.PERMISSION)
            return
        }
        bleScanTimeout = Runnable {
            if (current != generation || !active || !scanning) return@Runnable
            scanning = false
            stopBleScan()
            if (devices.isEmpty()) fail(Failure.NOT_FOUND)
        }.also { platform.postDelayed(it, BLE_SCAN_TIMEOUT_MS) }
    }

    private fun connectOnMain(id: String) {
        beginOperation()
        if (!isSupported()) return fail(Failure.UNSUPPORTED)
        val sdk = platform.sdkInt
        if (!platform.hasPermissions(cameraBluetoothPermissions(sdk) + cameraWifiPermissions(sdk))) return fail(Failure.PERMISSION)
        if (!platform.isBluetoothPresent()) return fail(Failure.UNSUPPORTED)
        val bluetoothEnabled = try { platform.isBluetoothEnabled() } catch (_: SecurityException) {
            fail(Failure.PERMISSION)
            return
        }
        if (!bluetoothEnabled) return fail(Failure.BLUETOOTH_OFF)
        if (!platform.isLocationEnabled()) return fail(Failure.LOCATION_OFF)

        val selected = devices.entries.firstOrNull { it.key.equals(id, ignoreCase = true) }?.value
            ?: return fail(Failure.NOT_FOUND)
        selectedDevice = selected
        selectedId = selected.id
        scanning = false
        stopBleScan()
        val bonded = try {
            selected.isBonded
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

    private fun isSupported(): Boolean = platform.sdkInt >= Build.VERSION_CODES.Q

    private fun handleScanResult(current: Long, entry: BleScanEntry) {
        if (current != generation || !active || !scanning) return
        if (!entry.isSony) return
        if (devices.putIfAbsent(entry.id, entry) == null) {
            deviceNames[entry.id] = entry.name
            emitCandidates()
        }
    }

    private fun emitCandidates() {
        listener.onCandidates(devices.map { CameraCandidate(it.key, deviceNames[it.key] ?: it.value.name) })
    }

    private fun openGatt() {
        val device = selectedDevice ?: return fail(Failure.BLUETOOTH)
        setStage(Stage.BLUETOOTH)
        if (!active) return
        try {
            gatt = device.connectGatt(gattCallback)
            if (gatt == null) fail(Failure.BLUETOOTH)
        } catch (_: SecurityException) {
            fail(Failure.PERMISSION)
        }
    }

    private fun isCurrentGatt(source: GattHandle): Boolean {
        if (!active || source !== gatt) return false
        val selectedAddress = selectedDevice?.id ?: return false
        val sourceAddress = try { source.address } catch (_: SecurityException) { return false }
        return selectedAddress == sourceAddress
    }

    private fun activateWifi(source: GattHandle) {
        if (!source.hasWifiOnCharacteristic()) return fail(Failure.WIFI)
        setStage(Stage.WIFI_STARTING)
        if (!active) return
        startBleTimeout(wifiStartingTimeoutMs)
        val wrote = try {
            source.writeWifiOn()
        } catch (_: SecurityException) {
            fail(Failure.PERMISSION)
            return
        }
        if (!wrote) fail(Failure.WIFI)
    }

    private fun scheduleSSIDRead(source: GattHandle) {
        ssidReadRunnable?.let(platform::removeCallbacks)
        val current = generation
        ssidReadRunnable = Runnable {
            ssidReadRunnable = null
            if (current != generation || !isCurrentGatt(source)) return@Runnable
            readAttempts++
            val read = try {
                source.readSsid()
            } catch (_: SecurityException) {
                fail(Failure.PERMISSION)
                return@Runnable
            }
            if (!read) fail(Failure.WIFI)
        }.also { platform.postDelayed(it, 3_000L) }
    }

    private fun handleCharacteristicRead(
        source: GattHandle,
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
                    val read = try {
                        source.readPassword()
                    } catch (_: SecurityException) {
                        fail(Failure.PERMISSION)
                        return
                    }
                    if (!read) fail(Failure.WIFI)
                }
                PASSWORD_CHARACTERISTIC -> {
                    val ssid = pendingSSID ?: return fail(Failure.WIFI)
                    pendingPassword = SonyWifiCredentials.decode(value, true)
                    wifiCredentialsReady = true
                    waitForAccessPoint(ssid)
                }
            }
        } catch (_: IllegalArgumentException) {
            fail(Failure.WIFI)
        }
    }

    private fun waitForAccessPoint(name: String) {
        if (pendingPassword == null || !platform.isWifiAvailable()) return fail(Failure.WIFI)
        if (!active) return
        cancelBleTimeout()
        closeGatt()
        scanStartedMicros = platform.elapsedMicros()
        pendingSSID = name
        if (!registerWifiReceiver() || !active) return
        val scanStarted = try {
            val started = platform.startWifiScan()
            findFreshAccessPoint()
            started
        } catch (_: SecurityException) {
            fail(Failure.PERMISSION)
            return
        }
        if (!active || pendingSSID == null) return
        if (!scanStarted) return fail(Failure.WIFI)
        val current = generation
        wifiScanTimeout = Runnable {
            if (current == generation && active && pendingSSID != null) fail(Failure.WIFI)
        }.also { platform.postDelayed(it, WIFI_SCAN_TIMEOUT_MS) }
    }

    private fun findFreshAccessPoint() {
        val name = pendingSSID ?: return
        if (!active || generation <= 0L || !platform.isWifiAvailable()) return
        val results = try { platform.wifiScanResults() } catch (_: SecurityException) {
            fail(Failure.PERMISSION)
            return
        }
        for (result in results) {
            val bssid = result.bssid ?: continue
            if (result.ssid == name && result.timestampMicros >= scanStartedMicros - WIFI_FRESHNESS_US) {
                requestWiFi(name, pendingPassword ?: return fail(Failure.WIFI), bssid)
                return
            }
        }
    }

    private fun requestWiFi(name: String, password: String, bssid: String) {
        if (platform.sdkInt < Build.VERSION_CODES.Q) {
            fail(Failure.UNSUPPORTED)
            return
        }
        unregisterWifiReceiver()
        pendingSSID = null
        pendingPassword = null
        cancelWifiScanTimeout()
        if (!platform.isConnectivityAvailable()) return fail(Failure.WIFI)
        val current = generation
        lateinit var handle: Handle
        val callbacks = object : WifiNetworkCallbacks {
            override fun onAvailable(network: Network, properties: LinkProperties?) {
                platform.post {
                    if (!isCurrentNetwork(current, handle)) return@post
                    inspectNetwork(network, properties, handle)
                }
            }

            override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
                platform.post {
                    if (!isCurrentNetwork(current, handle)) return@post
                    inspectNetwork(network, properties, handle)
                }
            }

            override fun onUnavailable() {
                platform.post {
                    if (isCurrentNetwork(current, handle)) fail(Failure.WIFI)
                }
            }

            override fun onLost(network: Network) {
                platform.post {
                    if (isCurrentNetwork(current, handle)) fail(Failure.DISCONNECTED)
                }
            }
        }
        setStage(Stage.WIFI_CONFIRMATION)
        if (!active) return
        try {
            handle = platform.requestWifiNetwork(name, password, bssid, callbacks)
            networkHandle = handle
        } catch (_: SecurityException) {
            fail(Failure.PERMISSION)
            return
        } catch (_: IllegalArgumentException) {
            fail(Failure.WIFI)
            return
        }
        if (active && stage == Stage.WIFI_CONFIRMATION && cameraNetwork == null && networkHandle === handle) {
            val timeoutGeneration = generation
            wifiRequestTimeout = Runnable {
                if (timeoutGeneration == generation && active && stage == Stage.WIFI_CONFIRMATION && cameraNetwork == null) {
                    fail(Failure.WIFI)
                }
            }.also { platform.postDelayed(it, wifiRequestTimeoutMs) }
        }
    }

    private fun isCurrentNetwork(current: Long, handle: Handle): Boolean =
        active && current == generation && networkHandle === handle

    private fun inspectNetwork(
        network: Network,
        properties: LinkProperties?,
        handle: Handle,
    ) {
        if (networkHandle !== handle || cameraNetwork != null) return
        val gateway = platform.defaultIpv4Gateway(properties) ?: return
        cameraNetwork = network
        cameraAddress = gateway
        cancelBleTimeout()
        cancelWifiRequestTimeout()
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

    private fun startBleTimeout(timeoutMs: Long = BLE_TIMEOUT_MS) {
        cancelBleTimeout()
        val current = generation
        bleTimeout = Runnable {
            if (current != generation || !active) return@Runnable
            when (stage) {
                Stage.PAIRING -> fail(Failure.PAIRING)
                Stage.BLUETOOTH -> fail(Failure.BLUETOOTH)
                Stage.WIFI_STARTING -> fail(Failure.WIFI)
                else -> Unit
            }
        }.also { platform.postDelayed(it, timeoutMs) }
    }

    private fun cancelBleTimeout() {
        bleTimeout?.let(platform::removeCallbacks)
        bleTimeout = null
    }

    private fun cancelWifiScanTimeout() {
        wifiScanTimeout?.let(platform::removeCallbacks)
        wifiScanTimeout = null
    }

    private fun cancelWifiRequestTimeout() {
        wifiRequestTimeout?.let(platform::removeCallbacks)
        wifiRequestTimeout = null
    }

    private fun closeGatt() {
        ssidReadRunnable?.let(platform::removeCallbacks)
        ssidReadRunnable = null
        val oldGatt = gatt
        gatt = null
        if (oldGatt != null) {
            try { oldGatt.disconnect() } catch (_: SecurityException) { }
            try { oldGatt.close() } catch (_: SecurityException) { }
        }
    }

    private fun fail(reason: Failure) {
        if (!active) return
        active = false
        releaseResources()
        listener.onFailure(reason)
    }

    private fun releaseResources() {
        scanning = false
        bleScanTimeout?.let(platform::removeCallbacks)
        bleScanTimeout = null
        cancelBleTimeout()
        cancelWifiScanTimeout()
        cancelWifiRequestTimeout()
        stopBleScan()
        unregisterBondReceiver()
        unregisterWifiReceiver()
        wifiCredentialsReady = false
        pendingSSID = null
        pendingPassword = null
        selectedDevice = null
        selectedId = null
        stage = null
        cameraNetwork = null
        cameraAddress = null
        val handle = networkHandle
        networkHandle = null
        if (handle != null) {
            try { handle.close() } catch (_: Exception) { }
        }
        closeGatt()
    }

    private fun stopBleScan() {
        val currentScanner = scanHandle ?: return
        scanHandle = null
        try { currentScanner.close() } catch (_: SecurityException) { }
    }

    private fun registerBondReceiver(): Boolean {
        if (bondReceiverHandle != null) return true
        val expectedGeneration = generation
        return try {
            bondReceiverHandle = platform.registerBondReceiver { deviceAddress, bondState ->
                if (!active || expectedGeneration != generation) return@registerBondReceiver
                val selectedAddress = selectedDevice?.id ?: return@registerBondReceiver
                if (selectedAddress != deviceAddress) return@registerBondReceiver
                when (bondState) {
                    BluetoothDevice.BOND_BONDED -> {
                        unregisterBondReceiver()
                        setStage(Stage.BLUETOOTH)
                        openGatt()
                    }
                    BluetoothDevice.BOND_NONE -> fail(Failure.PAIRING)
                }
            }
            true
        } catch (_: Exception) {
            fail(Failure.PAIRING)
            false
        }
    }

    private fun unregisterBondReceiver() {
        val handle = bondReceiverHandle ?: return
        bondReceiverHandle = null
        try { handle.close() } catch (_: Exception) { }
    }

    private fun registerWifiReceiver(): Boolean {
        if (wifiReceiverHandle != null) return true
        val expectedGeneration = generation
        return try {
            wifiReceiverHandle = platform.registerWifiScanReceiver {
                if (expectedGeneration == generation) findFreshAccessPoint()
            }
            true
        } catch (_: Exception) {
            fail(Failure.WIFI)
            false
        }
    }

    private fun unregisterWifiReceiver() {
        val handle = wifiReceiverHandle ?: return
        wifiReceiverHandle = null
        try { handle.close() } catch (_: Exception) { }
    }

    @SuppressLint("MissingPermission")
    private class AndroidPlatform(private val appContext: Context) : Platform {
        private val main = Handler(Looper.getMainLooper())
        private val bluetoothManager = appContext.getSystemService(BluetoothManager::class.java)
        private val connectivity = appContext.getSystemService(ConnectivityManager::class.java)
        private val wifi = appContext.getSystemService(WifiManager::class.java)
        private val location = appContext.getSystemService(LocationManager::class.java)

        override val sdkInt: Int get() = Build.VERSION.SDK_INT
        override fun isMainThread(): Boolean = Looper.myLooper() == Looper.getMainLooper()
        override fun post(action: Runnable) { main.post(action) }
        override fun postDelayed(action: Runnable, delayMs: Long) { main.postDelayed(action, delayMs) }
        override fun removeCallbacks(action: Runnable) { main.removeCallbacks(action) }
        override fun elapsedMicros(): Long = SystemClock.elapsedRealtimeNanos() / 1_000L
        override fun hasPermissions(permissions: List<String>): Boolean =
            permissions.all { appContext.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
        override fun isBluetoothPresent(): Boolean = bluetoothManager?.adapter != null
        override fun isBluetoothEnabled(): Boolean = bluetoothManager?.adapter?.isEnabled == true
        override fun isLocationEnabled(): Boolean =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && location?.isLocationEnabled == true

        override fun startBleScan(onEntry: (BleScanEntry) -> Unit, onFailed: (Int) -> Unit): Handle? {
            val scanner: BluetoothLeScanner = bluetoothManager?.adapter?.bluetoothLeScanner ?: return null
            val callback = object : ScanCallback() {
                override fun onScanResult(callbackType: Int, result: ScanResult) {
                    toBleEntry(result)?.let(onEntry)
                }
                override fun onBatchScanResults(results: MutableList<ScanResult>) {
                    results.forEach { toBleEntry(it)?.let(onEntry) }
                }
                override fun onScanFailed(errorCode: Int) = onFailed(errorCode)
            }
            scanner.startScan(callback)
            return object : Handle {
                override fun close() {
                    scanner.stopScan(callback)
                }
            }
        }

        private fun toBleEntry(result: ScanResult): BleScanEntry? {
            val record: ScanRecord = result.scanRecord ?: return null
            val services = record.serviceUuids.orEmpty().map { it.uuid }
            val isSony = record.getManufacturerSpecificData(SONY_MANUFACTURER_ID) != null ||
                CONTROL_SERVICE in services || PAIRING_SERVICE in services
            if (!isSony) return null
            val device = result.device
            val id = device.address
            val name = record.deviceName?.takeIf { it.isNotBlank() } ?: SONY_CAMERA_LABEL
            return BleScanEntry(
                id = id,
                name = name,
                isSony = true,
                isBonded = device.bondState == BluetoothDevice.BOND_BONDED,
                connectGatt = { cb -> connectAndroidGatt(device, cb) },
                createBond = { device.createBond() },
            )
        }

        private fun connectAndroidGatt(device: BluetoothDevice, callback: GattClientCallback): GattHandle? {
            lateinit var handle: AndroidGattHandle
            val androidCallback = object : BluetoothGattCallback() {
                override fun onConnectionStateChange(source: BluetoothGatt, status: Int, newState: Int) {
                    callback.onConnectionStateChange(handle, status, newState)
                }
                override fun onMtuChanged(source: BluetoothGatt, mtu: Int, status: Int) {
                    callback.onMtuChanged(handle, mtu, status)
                }
                override fun onServicesDiscovered(source: BluetoothGatt, status: Int) {
                    callback.onServicesDiscovered(handle, status)
                }
                override fun onCharacteristicWrite(source: BluetoothGatt, item: BluetoothGattCharacteristic, status: Int) {
                    callback.onCharacteristicWrite(handle, item.uuid, status)
                }
                @Suppress("DEPRECATION")
                override fun onCharacteristicRead(source: BluetoothGatt, item: BluetoothGattCharacteristic, status: Int) {
                    callback.onCharacteristicRead(handle, item.uuid, item.value, status)
                }
            }
            val rawGatt = device.connectGatt(appContext, false, androidCallback, BluetoothDevice.TRANSPORT_LE) ?: return null
            handle = AndroidGattHandle(rawGatt)
            return handle
        }

        override fun registerBondReceiver(onBondChanged: (address: String, bondState: Int) -> Unit): Handle {
            val receiver = object : BroadcastReceiver() {
                @Suppress("DEPRECATION")
                override fun onReceive(context: Context, intent: Intent) {
                    val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE) ?: return
                    val bondState = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.BOND_NONE)
                    onBondChanged(device.address, bondState)
                }
            }
            val filter = IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                appContext.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                appContext.registerReceiver(receiver, filter)
            }
            return object : Handle {
                override fun close() { appContext.unregisterReceiver(receiver) }
            }
        }

        override fun isWifiAvailable(): Boolean = wifi != null

        @Suppress("DEPRECATION")
        override fun startWifiScan(): Boolean = wifi?.startScan() == true

        @Suppress("DEPRECATION")
        override fun wifiScanResults(): List<WifiApResult> =
            wifi?.scanResults.orEmpty().map { WifiApResult(it.SSID, it.BSSID, it.timestamp) }

        override fun registerWifiScanReceiver(onScanResults: () -> Unit): Handle {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    if (intent.action == WifiManager.SCAN_RESULTS_AVAILABLE_ACTION) onScanResults()
                }
            }
            val filter = IntentFilter(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                appContext.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                appContext.registerReceiver(receiver, filter)
            }
            return object : Handle {
                override fun close() { appContext.unregisterReceiver(receiver) }
            }
        }

        override fun isConnectivityAvailable(): Boolean = connectivity != null

        override fun requestWifiNetwork(
            ssid: String,
            password: String,
            bssid: String,
            callbacks: WifiNetworkCallbacks,
        ): Handle {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                throw UnsupportedOperationException("WifiNetworkSpecifier requires Android 10+")
            }
            val manager = checkNotNull(connectivity)
            val specifier = WifiNetworkSpecifier.Builder()
                .setSsid(ssid)
                .setBssid(MacAddress.fromString(bssid))
                .setWpa2Passphrase(password)
                .build()
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .setNetworkSpecifier(specifier)
                .build()
            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) =
                    callbacks.onAvailable(network, manager.getLinkProperties(network))
                override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) =
                    callbacks.onLinkPropertiesChanged(network, properties)
                override fun onUnavailable() = callbacks.onUnavailable()
                override fun onLost(network: Network) = callbacks.onLost(network)
            }
            manager.requestNetwork(request, callback)
            return object : Handle {
                override fun close() { manager.unregisterNetworkCallback(callback) }
            }
        }

        override fun registerManualWifiNetwork(callbacks: LegacyWifiCallbacks): Handle {
            val manager = checkNotNull(connectivity)
            class ManualWifiCallback : ConnectivityManager.NetworkCallback {
                constructor() : super()
                @androidx.annotation.RequiresApi(Build.VERSION_CODES.S)
                constructor(flags: Int) : super(flags)

                private val capabilitiesByNetwork = mutableMapOf<Network, NetworkCapabilities>()
                private val propertiesByNetwork = mutableMapOf<Network, LinkProperties>()

                @Suppress("DEPRECATION")
                private fun inspect(network: Network) {
                    if (Build.VERSION.SDK_INT < 29) return
                    val capabilities = capabilitiesByNetwork[network] ?: return
                    val properties = propertiesByNetwork[network] ?: return
                    if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return
                    val info = capabilities.transportInfo as? WifiInfo
                    var identity = SonyCameraModel.networkIdentity(info?.ssid, info?.bssid)
                    // 旧系统没有位置回调标志；新系统只信任对应 Network 的回调，避免套用另一条 Wi-Fi 的身份。
                    if (identity == null && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                        val legacy = wifi?.connectionInfo
                        identity = SonyCameraModel.networkIdentity(legacy?.ssid, legacy?.bssid)
                    }
                    identity ?: return
                    callbacks.onLegacyNetworkReady(network, identity, properties)
                }

                override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                    capabilitiesByNetwork[network] = capabilities
                    inspect(network)
                }
                override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
                    propertiesByNetwork[network] = properties
                    inspect(network)
                }
                override fun onLost(network: Network) {
                    capabilitiesByNetwork.remove(network)
                    propertiesByNetwork.remove(network)
                    callbacks.onLost(network)
                }
            }
            val callback = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                ManualWifiCallback(ConnectivityManager.NetworkCallback.FLAG_INCLUDE_LOCATION_INFO)
            else ManualWifiCallback()
            manager.registerNetworkCallback(
                NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                    .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build(),
                callback,
            )
            return object : Handle {
                override fun close() { manager.unregisterNetworkCallback(callback) }
            }
        }
    }

    @SuppressLint("MissingPermission")
    private class AndroidGattHandle(private val source: BluetoothGatt) : GattHandle {
        override val address: String? get() = source.device.address
        override fun requestMtu(mtu: Int): Boolean = source.requestMtu(mtu)
        override fun discoverServices(): Boolean = source.discoverServices()

        private fun characteristic(serviceUuid: UUID, characteristicUuid: UUID): BluetoothGattCharacteristic? =
            source.getService(serviceUuid)?.getCharacteristic(characteristicUuid)

        override fun hasRequiredCharacteristics(): Boolean {
            val command = characteristic(CONTROL_SERVICE, WIFI_ON_CHARACTERISTIC)
            val ssid = characteristic(CONTROL_SERVICE, SSID_CHARACTERISTIC)
            val password = characteristic(CONTROL_SERVICE, PASSWORD_CHARACTERISTIC)
            val pairing = characteristic(PAIRING_SERVICE, PAIRING_INIT_CHARACTERISTIC)
            return command != null && ssid != null && password != null && pairing != null &&
                command.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0 &&
                pairing.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0 &&
                ssid.properties and BluetoothGattCharacteristic.PROPERTY_READ != 0 &&
                password.properties and BluetoothGattCharacteristic.PROPERTY_READ != 0
        }

        override fun hasWifiOnCharacteristic(): Boolean =
            characteristic(CONTROL_SERVICE, WIFI_ON_CHARACTERISTIC) != null

        @Suppress("DEPRECATION")
        override fun writePairingInit(): Boolean {
            val pairing = characteristic(PAIRING_SERVICE, PAIRING_INIT_CHARACTERISTIC) ?: return false
            pairing.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            pairing.value = byteArrayOf(6, 8, 1, 0, 0, 0, 0)
            return source.writeCharacteristic(pairing)
        }

        @Suppress("DEPRECATION")
        override fun writeWifiOn(): Boolean {
            val command = characteristic(CONTROL_SERVICE, WIFI_ON_CHARACTERISTIC) ?: return false
            command.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            command.value = byteArrayOf(1)
            return source.writeCharacteristic(command)
        }

        override fun readSsid(): Boolean {
            val c = characteristic(CONTROL_SERVICE, SSID_CHARACTERISTIC) ?: return false
            return source.readCharacteristic(c)
        }

        override fun readPassword(): Boolean {
            val c = characteristic(CONTROL_SERVICE, PASSWORD_CHARACTERISTIC) ?: return false
            return source.readCharacteristic(c)
        }

        override fun disconnect() = source.disconnect()
        override fun close() = source.close()
    }
}
