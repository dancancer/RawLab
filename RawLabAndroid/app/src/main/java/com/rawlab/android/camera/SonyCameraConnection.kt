package com.rawlab.android.camera

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanRecord
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
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
import android.util.Log
import com.rawlab.android.BuildConfig
import com.rawlab.android.camera.protocol.SonyWifiCredentials
import java.io.Closeable
import java.net.Inet4Address
import java.net.InetAddress
import java.util.LinkedHashMap
import java.util.Locale
import java.util.UUID

internal data class CameraCandidate(val id: String, val name: String)

/** 只管理 Android BLE/Wi-Fi 连接；PTP、凭据持久化、进程绑网和解绑不在此处。 */
internal class SonyCameraConnection internal constructor(
    context: Context,
    private val listener: Listener,
    private val platform: Platform,
    private val wifiStartingTimeoutMs: Long = WIFI_STARTING_TIMEOUT_MS,
    private val wifiRequestTimeoutMs: Long = WIFI_REQUEST_TIMEOUT_MS,
    private val wifiScanFallbackMs: Long = WIFI_SCAN_FALLBACK_MS,
    private val manualWifiTimeoutMs: Long = MANUAL_WIFI_TIMEOUT_MS,
) : Closeable {
    constructor(context: Context, listener: Listener) : this(
        context,
        listener,
        AndroidPlatform(context.applicationContext),
    )

    interface Listener {
        fun onCandidates(items: List<CameraCandidate>)
        fun onStage(stage: Stage)
        /** 相机未提供 Sony BLE 自动拉起 Wi-Fi 服务，已自动切换至手动 Wi-Fi 引导。 */
        fun onManualWifiFallback() {}
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

    internal enum class WifiSecurity {
        WPA2,
        WPA3,
    }

    internal data class WifiApResult(
        val ssid: String?,
        val bssid: String?,
        val timestampMicros: Long,
        val capabilities: String = "",
    )

    internal interface Handle {
        fun close()
    }

    internal interface GattHandle {
        val address: String?
        fun requestMtu(mtu: Int): Boolean
        fun discoverServices(): Boolean
        fun hasRequiredCharacteristics(): Boolean
        fun hasWifiOnCharacteristic(): Boolean
        fun sonyServiceSummary(): String = ""
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
        fun registerWifiScanReceiver(onScanResults: (updated: Boolean) -> Unit): Handle
        fun isConnectivityAvailable(): Boolean
        fun requestWifiNetwork(ssid: String, password: String, bssid: String?, callbacks: WifiNetworkCallbacks): Handle
        fun requestWifiNetwork(
            ssid: String,
            password: String,
            bssid: String?,
            security: WifiSecurity,
            callbacks: WifiNetworkCallbacks,
        ): Handle = requestWifiNetwork(ssid, password, bssid, callbacks)
        fun registerManualWifiNetwork(callbacks: LegacyWifiCallbacks): Handle
        fun defaultIpv4Gateway(properties: LinkProperties?): Inet4Address? {
            if (properties == null) return null
            val routes = properties.routes.map { route ->
                val isDefault = route.isDefaultRoute
                val prefixLen = route.destination.prefixLength
                val hasGw = if (sdkInt >= Build.VERSION_CODES.Q && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    route.hasGateway()
                } else {
                    route.gateway != null
                }
                Ipv4RouteCandidate(
                    isDefaultRoute = isDefault,
                    hasGateway = hasGw,
                    gateway = route.gateway as? Inet4Address,
                    destinationPrefixLength = prefixLen,
                )
            }
            val dhcp = if (sdkInt >= Build.VERSION_CODES.R && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                properties.dhcpServerAddress
            } else {
                null
            }
            val links = properties.linkAddresses.mapNotNull { link ->
                val v4 = link.address as? Inet4Address ?: return@mapNotNull null
                Ipv4LinkCandidate(v4, link.prefixLength)
            }
            val dns = properties.dnsServers.mapNotNull { it as? Inet4Address }
            return resolveCameraIpv4Gateway(
                routes = routes,
                dhcpServerAddress = dhcp,
                linkAddresses = links,
                dnsServers = dns,
            )
        }
    }

    private companion object {
        const val SONY_MANUFACTURER_ID = 0x012d
        const val SONY_CAMERA_LABEL = "Sony camera"
        const val BLE_MTU = 158
        const val BLE_TIMEOUT_MS = 3 * 60 * 1000L
        const val WIFI_STARTING_TIMEOUT_MS = 45 * 1000L
        const val WIFI_REQUEST_TIMEOUT_MS = 60 * 1000L
        const val WIFI_SCAN_FALLBACK_MS = 4_000L
        const val MANUAL_WIFI_TIMEOUT_MS = 15_000L
        const val BLE_SCAN_TIMEOUT_MS = 25 * 1000L
        const val MAX_GATT_CONNECT_ATTEMPTS = 3
        const val GATT_RETRY_BASE_DELAY_MS = 400L
        const val WIFI_FRESHNESS_US = 2_000_000L

        val CONTROL_SERVICE = UUID.fromString("8000cc00-cc00-ffff-ffff-ffffffffffff")
        val PAIRING_SERVICE = UUID.fromString("8000ee00-ee00-ffff-ffff-ffffffffffff")

        fun sonyCharacteristic(suffix: String): UUID =
            UUID.fromString("0000${suffix.lowercase()}-0000-1000-8000-00805f9b34fb")

        val SSID_CHARACTERISTIC = sonyCharacteristic("cc06")
        val PASSWORD_CHARACTERISTIC = sonyCharacteristic("cc07")
        val WIFI_ON_CHARACTERISTIC = sonyCharacteristic("cc08")
        val PAIRING_INIT_CHARACTERISTIC = sonyCharacteristic("ee01")

        fun shortUuid(uuid: UUID): String = uuid.toString().substring(4, 8)

        fun debugLog(message: String) {
            if (BuildConfig.DEBUG) {
                runCatching { Log.d("RawLabCamera", message) }
            }
        }
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
    private var gattConnectAttempts = 0
    private var gattConnected = false
    private var deviceBonded = false
    private var gattServicesDiscovered = false
    private var negotiatedMtu = 0
    private var usingPreBondGatt = false
    private var retriedPostBondGatt = false
    private var scanStartedMicros = 0L
    private var pendingSSID: String? = null
    private var pendingPassword: String? = null
    private var activeWifiCapabilities = ""
    private var activeWifiSecurity = WifiSecurity.WPA2
    private var retriedWpa3 = false

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
    private var gattRetryRunnable: Runnable? = null

    private val gattCallback = object : GattClientCallback {
        override fun onConnectionStateChange(source: GattHandle, status: Int, newState: Int) {
            platform.post {
                if (!isCurrentGatt(source)) return@post
                debugLog("GATT onConnectionStateChange status=$status newState=$newState stage=$stage attempt=$gattConnectAttempts")
                CameraDiagnostics.breadcrumb(
                    stage = "gattConnectionState",
                    message = "BLE GATT connection state changed",
                    level = if (status == BluetoothGatt.GATT_SUCCESS) "info" else "warn",
                    context = mapOf(
                        "gattStatus" to status.toString(),
                        "newState" to newState.toString(),
                        "stage" to (stage?.name ?: "NONE"),
                        "attempt" to gattConnectAttempts.toString(),
                        "bonded" to deviceBonded.toString(),
                    ),
                )
                if (status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED) {
                    gattConnected = true
                    negotiatedMtu = 0
                    gattServicesDiscovered = false
                    val requested = try {
                        source.requestMtu(BLE_MTU)
                    } catch (_: SecurityException) {
                        fail(Failure.PERMISSION, "requestMtu SecurityException")
                        return@post
                    }
                    if (!requested) {
                        val discovered = try {
                            source.discoverServices()
                        } catch (_: SecurityException) {
                            fail(Failure.PERMISSION, "discoverServices SecurityException")
                            return@post
                        }
                        if (!discovered) fail(Failure.BLUETOOTH, "requestMtu and discoverServices returned false")
                    }
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) {
                    val wasConnected = gattConnected
                    gattConnected = false
                    gattServicesDiscovered = false
                    if (stage == Stage.PAIRING) {
                        // Peer or OS dropped GATT during SMP bonding; keep waiting for ACTION_BOND_STATE_CHANGED.
                        closeGatt()
                    } else if (stage == Stage.BLUETOOTH && !wasConnected &&
                        status != BluetoothGatt.GATT_SUCCESS && gattConnectAttempts < MAX_GATT_CONNECT_ATTEMPTS
                    ) {
                        val current = generation
                        val delayMs = GATT_RETRY_BASE_DELAY_MS * gattConnectAttempts
                        debugLog("BLE GATT connect failed status=$status attempt=$gattConnectAttempts; retrying in ${delayMs}ms")
                        closeGatt()
                        gattRetryRunnable?.let(platform::removeCallbacks)
                        gattRetryRunnable = Runnable {
                            gattRetryRunnable = null
                            if (current == generation && active && stage == Stage.BLUETOOTH) {
                                openGatt()
                            }
                        }.also { platform.postDelayed(it, delayMs) }
                    } else if (stage == Stage.BLUETOOTH || (stage == Stage.WIFI_STARTING && !wifiCredentialsReady)) {
                        fail(
                            Failure.BLUETOOTH,
                            "gatt disconnect status=$status newState=$newState attempt=$gattConnectAttempts",
                        )
                    }
                }
            }
        }

        override fun onMtuChanged(source: GattHandle, mtu: Int, status: Int) {
            platform.post {
                if (!isCurrentGatt(source)) return@post
                debugLog("GATT onMtuChanged mtu=$mtu status=$status")
                negotiatedMtu = if (status == BluetoothGatt.GATT_SUCCESS) mtu else 0
                CameraDiagnostics.breadcrumb(
                    stage = "gattMtuChanged",
                    message = "BLE GATT MTU negotiated",
                    level = if (status == BluetoothGatt.GATT_SUCCESS && mtu >= 67) "info" else "warn",
                    context = mapOf(
                        "mtu" to mtu.toString(),
                        "gattStatus" to status.toString(),
                    ),
                )
                // Always discover services before rejecting small MTU so cameras without
                // Sony BLE Wi-Fi handoff services (e.g. ZV-E10) cleanly fall back to MANUAL_WIFI.
                val discovered = try {
                    source.discoverServices()
                } catch (_: SecurityException) {
                    fail(Failure.PERMISSION, "discoverServices SecurityException")
                    return@post
                }
                if (!discovered) fail(Failure.BLUETOOTH, "discoverServices returned false")
            }
        }

        override fun onServicesDiscovered(source: GattHandle, status: Int) {
            platform.post {
                if (!isCurrentGatt(source)) return@post
                val hasRequired = if (status == BluetoothGatt.GATT_SUCCESS) source.hasRequiredCharacteristics() else false
                val hasWifiOn = if (status == BluetoothGatt.GATT_SUCCESS) source.hasWifiOnCharacteristic() else false
                val sonyServices = if (status == BluetoothGatt.GATT_SUCCESS) source.sonyServiceSummary() else ""
                debugLog("GATT onServicesDiscovered status=$status hasRequired=$hasRequired hasWifiOn=$hasWifiOn mtu=$negotiatedMtu services=$sonyServices")
                CameraDiagnostics.breadcrumb(
                    stage = "gattServicesDiscovered",
                    message = "BLE GATT services discovered",
                    level = if (status == BluetoothGatt.GATT_SUCCESS) "info" else "warn",
                    context = buildMap {
                        put("gattStatus", status.toString())
                        put("hasRequired", hasRequired.toString())
                        put("hasWifiOn", hasWifiOn.toString())
                        put("mtu", negotiatedMtu.toString())
                        put("bonded", deviceBonded.toString())
                        if (sonyServices.isNotBlank()) put("sonyServices", sonyServices)
                    },
                )
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    fail(Failure.BLUETOOTH, "discoverServices status=$status")
                    return@post
                }
                if (!hasRequired) {
                    CameraDiagnostics.breadcrumb(
                        stage = "bleManualWifiFallback",
                        message = "Camera lacks Sony BLE Wi-Fi handoff characteristics; switching to manual Wi-Fi",
                        level = "warn",
                        context = buildMap {
                            put("hasWifiOn", hasWifiOn.toString())
                            put("mtu", negotiatedMtu.toString())
                            if (sonyServices.isNotBlank()) put("sonyServices", sonyServices)
                        },
                    )
                    beginOperation()
                    setStage(Stage.MANUAL_WIFI)
                    if (active) listener.onManualWifiFallback()
                    return@post
                }
                gattServicesDiscovered = true
                if (!deviceBonded) {
                    startBonding()
                    return@post
                }
                proceedAfterBondedAndDiscovered(source)
            }
        }

        override fun onCharacteristicWrite(source: GattHandle, uuid: UUID, status: Int) {
            platform.post {
                if (!isCurrentGatt(source)) return@post
                debugLog("GATT onCharacteristicWrite uuid=${shortUuid(uuid)} status=$status")
                CameraDiagnostics.breadcrumb(
                    stage = "gattWrite",
                    message = "BLE characteristic write completed",
                    level = if (status == BluetoothGatt.GATT_SUCCESS) "info" else "warn",
                    context = mapOf(
                        "uuid" to shortUuid(uuid),
                        "gattStatus" to status.toString(),
                    ),
                )
                when (uuid) {
                    PAIRING_INIT_CHARACTERISTIC -> {
                        if (status != BluetoothGatt.GATT_SUCCESS) {
                            if (usingPreBondGatt && !retriedPostBondGatt) {
                                retriedPostBondGatt = true
                                usingPreBondGatt = false
                                CameraDiagnostics.breadcrumb(
                                    stage = "gattPostBondRetry",
                                    message = "ee01 write failed on pre-bond GATT handle; reopening GATT",
                                    level = "warn",
                                    context = mapOf("gattStatus" to status.toString()),
                                )
                                closeGatt()
                                gattConnectAttempts = 0
                                openGatt()
                            } else {
                                fail(Failure.PAIRING, "ee01 write status=$status")
                            }
                        } else {
                            usingPreBondGatt = false
                            activateWifi(source)
                        }
                    }
                    WIFI_ON_CHARACTERISTIC -> {
                        if (status != BluetoothGatt.GATT_SUCCESS) {
                            fail(Failure.WIFI, "cc08 write status=$status")
                        } else {
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
                debugLog("Manual Wi-Fi registered")
                CameraDiagnostics.breadcrumb(
                    stage = "manualWifiStart",
                    message = "Listening for manually connected camera Wi-Fi",
                )
            } catch (_: SecurityException) {
                fail(Failure.PERMISSION, "registerManualWifiNetwork SecurityException")
                return@post
            }
            if (active && stage == Stage.MANUAL_WIFI && cameraNetwork == null && networkHandle === handle) {
                val timeoutGeneration = generation
                wifiRequestTimeout = Runnable {
                    if (timeoutGeneration == generation && active && stage == Stage.MANUAL_WIFI && cameraNetwork == null) {
                        debugLog("Manual Wi-Fi timed out waiting for camera network")
                        fail(Failure.WIFI, "manual Wi-Fi timeout")
                    }
                }.also { platform.postDelayed(it, manualWifiTimeoutMs) }
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
                onFailed = { errorCode ->
                    platform.post {
                        if (current == generation && active && scanning) {
                            fail(Failure.BLUETOOTH, "BLE scan failed errorCode=$errorCode")
                        }
                    }
                },
            ) ?: return fail(Failure.BLUETOOTH, "BluetoothLeScanner unavailable")
            scanHandle = handle
            CameraDiagnostics.breadcrumb(
                stage = "bleScanStart",
                message = "Started BLE scan for Sony cameras",
            )
        } catch (_: SecurityException) {
            fail(Failure.PERMISSION, "startBleScan SecurityException")
            return
        }
        bleScanTimeout = Runnable {
            if (current != generation || !active || !scanning) return@Runnable
            scanning = false
            stopBleScan()
            if (devices.isEmpty()) fail(Failure.NOT_FOUND, "BLE scan timed out with 0 candidates")
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
            ?: return fail(Failure.NOT_FOUND, "selected BLE candidate missing")
        selectedDevice = selected
        selectedId = selected.id
        deviceBonded = try {
            selected.isBonded
        } catch (_: SecurityException) {
            fail(Failure.PERMISSION, "isBonded SecurityException")
            return
        }
        scanning = false
        stopBleScan()
        CameraDiagnostics.breadcrumb(
            stage = "bleConnectStart",
            message = "Connecting to selected Sony camera over BLE GATT",
            context = mapOf(
                "bonded" to deviceBonded.toString(),
                "knownModel" to SonyCameraModel.fromAdvertisement(selected.name).name,
            ),
        )
        // Always probe GATT services before initiating OS bonding so cameras without
        // Sony BLE Wi-Fi handoff services (e.g. ZV-E10) fall back to MANUAL_WIFI
        // instead of failing at createBond().
        setStage(Stage.BLUETOOTH)
        if (!active) return
        startBleTimeout()
        openGatt()
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
            debugLog("BLE candidate discovered (total=${devices.size})")
            CameraDiagnostics.breadcrumb(
                stage = "bleCandidateFound",
                message = "Discovered Sony BLE candidate",
                context = mapOf(
                    "candidateCount" to devices.size.toString(),
                    "knownModel" to SonyCameraModel.fromAdvertisement(entry.name).name,
                    "bonded" to entry.isBonded.toString(),
                ),
            )
            emitCandidates()
        }
    }

    private fun emitCandidates() {
        listener.onCandidates(devices.map { CameraCandidate(it.key, deviceNames[it.key] ?: it.value.name) })
    }

    private fun openGatt() {
        val device = selectedDevice ?: return fail(Failure.BLUETOOTH, "missing selected device for GATT")
        setStage(Stage.BLUETOOTH)
        if (!active) return
        gattConnectAttempts++
        gattConnected = false
        gattServicesDiscovered = false
        negotiatedMtu = 0
        usingPreBondGatt = false
        debugLog("Opening GATT (attempt=$gattConnectAttempts)")
        CameraDiagnostics.breadcrumb(
            stage = "gattOpen",
            message = "Opening BLE GATT connection",
            context = mapOf(
                "attempt" to gattConnectAttempts.toString(),
                "bonded" to deviceBonded.toString(),
            ),
        )
        try {
            gatt = device.connectGatt(gattCallback)
            if (gatt == null) fail(Failure.BLUETOOTH, "connectGatt returned null")
        } catch (_: SecurityException) {
            fail(Failure.PERMISSION, "connectGatt SecurityException")
        }
    }

    private fun startBonding() {
        val selected = selectedDevice ?: return fail(Failure.PAIRING, "missing selected device for bonding")
        setStage(Stage.PAIRING)
        if (!active) return
        startBleTimeout()
        CameraDiagnostics.breadcrumb(
            stage = "bleBondStart",
            message = "Initiating Bluetooth bond after verifying Sony BLE services",
            context = mapOf("mtu" to negotiatedMtu.toString()),
        )
        try {
            if (registerBondReceiver() && active && !selected.createBond()) {
                fail(Failure.PAIRING, "createBond returned false")
            }
        } catch (_: SecurityException) {
            fail(Failure.PERMISSION, "createBond SecurityException")
        }
    }

    private fun proceedAfterBondedAndDiscovered(source: GattHandle) {
        if (negotiatedMtu < 67) {
            fail(Failure.BLUETOOTH, "negotiated MTU too small: $negotiatedMtu")
            return
        }
        val wrote = try {
            source.writePairingInit()
        } catch (_: SecurityException) {
            fail(Failure.PERMISSION, "writePairingInit SecurityException")
            return
        }
        if (!wrote) fail(Failure.BLUETOOTH, "writePairingInit returned false")
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
        debugLog("GATT onCharacteristicRead uuid=${shortUuid(key)} status=$status bytes=${value?.size ?: 0}")
        CameraDiagnostics.breadcrumb(
            stage = "gattRead",
            message = "BLE characteristic read completed",
            level = if (status == BluetoothGatt.GATT_SUCCESS) "info" else "warn",
            context = mapOf(
                "uuid" to shortUuid(key),
                "gattStatus" to status.toString(),
                "bytes" to (value?.size ?: 0).toString(),
                "attempt" to readAttempts.toString(),
            ),
        )
        if (status != BluetoothGatt.GATT_SUCCESS) {
            if (key == SSID_CHARACTERISTIC && status == 157 && readAttempts < 8) {
                scheduleSSIDRead(source)
            } else {
                fail(Failure.WIFI, "gatt read uuid=${shortUuid(key)} status=$status attempt=$readAttempts")
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
        val password = pendingPassword ?: return fail(Failure.WIFI)
        if (!active) return
        cancelBleTimeout()
        closeGatt()
        scanStartedMicros = platform.elapsedMicros()
        pendingSSID = name
        val wifiAvailable = platform.isWifiAvailable()
        debugLog("Waiting for AP broadcast (wifiAvailable=$wifiAvailable)")
        if (!wifiAvailable) {
            requestWiFi(name, password, bssid = null)
            return
        }
        findFreshAccessPoint()
        if (!active || pendingSSID == null) return
        if (!registerWifiReceiver() || !active) return
        val scanStarted = try {
            platform.startWifiScan()
        } catch (_: SecurityException) {
            fail(Failure.PERMISSION)
            return
        }
        debugLog("startWifiScan returned $scanStarted")
        findFreshAccessPoint()
        if (!active || pendingSSID == null) return
        if (!scanStarted) {
            fallbackToSsidOnlyWifi()
            return
        }
        val current = generation
        wifiScanTimeout = Runnable {
            if (current == generation && active && pendingSSID != null) {
                fallbackToSsidOnlyWifi()
            }
        }.also { platform.postDelayed(it, wifiScanFallbackMs) }
    }

    private fun fallbackToSsidOnlyWifi() {
        val ssid = pendingSSID ?: return
        val password = pendingPassword ?: return fail(Failure.WIFI)
        val cachedCaps = findMatchingApCapabilities(ssid)
        val security = selectWifiSecurity(cachedCaps)
        debugLog("Wi-Fi scan unavailable/timed out; requesting WifiNetworkSpecifier by SSID only security=$security")
        requestWiFi(ssid, password, bssid = null, security = security, capabilities = cachedCaps)
    }

    private fun findMatchingApCapabilities(ssid: String): String {
        val results = try {
            platform.wifiScanResults()
        } catch (_: SecurityException) {
            return ""
        }
        return results
            .asSequence()
            .filter { it.ssid == ssid && it.capabilities.isNotBlank() }
            .maxByOrNull { it.timestampMicros }
            ?.capabilities
            .orEmpty()
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
                val security = selectWifiSecurity(result.capabilities)
                debugLog("Found fresh cached AP; requesting WifiNetworkSpecifier (withBssid=true, security=$security)")
                requestWiFi(
                    name = name,
                    password = pendingPassword ?: return fail(Failure.WIFI),
                    bssid = bssid,
                    security = security,
                    capabilities = result.capabilities,
                )
                return
            }
        }
    }

    private fun requestWiFi(
        name: String,
        password: String,
        bssid: String?,
        security: WifiSecurity = WifiSecurity.WPA2,
        capabilities: String = "",
        isRetry: Boolean = false,
    ) {
        if (platform.sdkInt < Build.VERSION_CODES.Q) {
            fail(Failure.UNSUPPORTED)
            return
        }
        unregisterWifiReceiver()
        pendingSSID = null
        pendingPassword = null
        cancelWifiScanTimeout()
        activeWifiCapabilities = capabilities
        activeWifiSecurity = security
        if (!isRetry) retriedWpa3 = false
        if (!platform.isConnectivityAvailable()) return fail(Failure.WIFI)
        val current = generation
        lateinit var handle: Handle
        val callbacks = object : WifiNetworkCallbacks {
            override fun onAvailable(network: Network, properties: LinkProperties?) {
                platform.post {
                    if (!isCurrentNetwork(current, handle)) return@post
                    debugLog("WifiNetworkCallbacks.onAvailable hasProps=${properties != null}")
                    inspectNetwork(network, properties, handle)
                }
            }

            override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
                platform.post {
                    if (!isCurrentNetwork(current, handle)) return@post
                    debugLog("WifiNetworkCallbacks.onLinkPropertiesChanged")
                    inspectNetwork(network, properties, handle)
                }
            }

            override fun onUnavailable() {
                platform.post {
                    if (!isCurrentNetwork(current, handle)) return@post
                    val latestCaps = activeWifiCapabilities.ifBlank { findMatchingApCapabilities(name) }
                    val shouldRetryWpa3 =
                        activeWifiSecurity == WifiSecurity.WPA2 &&
                            !retriedWpa3 &&
                            (latestCaps.isBlank() || advertisesWpa3Sae(latestCaps))
                    if (shouldRetryWpa3) {
                        debugLog("WifiNetworkCallbacks.onUnavailable under WPA2 (capsBlank=${latestCaps.isBlank()}); retrying with WPA3")
                        CameraDiagnostics.breadcrumb(
                            stage = "wifiRetryWpa3",
                            message = "Camera Wi-Fi unavailable under WPA2; retrying with WPA3",
                            level = "warn",
                            context = mapOf("capsBlank" to latestCaps.isBlank().toString()),
                        )
                        retriedWpa3 = true
                        networkHandle = null
                        cancelWifiRequestTimeout()
                        runCatching { handle.close() }
                        requestWiFi(
                            name = name,
                            password = password,
                            bssid = bssid,
                            security = WifiSecurity.WPA3,
                            capabilities = latestCaps,
                            isRetry = true,
                        )
                        return@post
                    }
                    debugLog("WifiNetworkCallbacks.onUnavailable")
                    fail(Failure.WIFI, "WifiNetworkSpecifier onUnavailable security=$activeWifiSecurity retriedWpa3=$retriedWpa3")
                }
            }

            override fun onLost(network: Network) {
                platform.post {
                    if (isCurrentNetwork(current, handle)) {
                        debugLog("WifiNetworkCallbacks.onLost")
                        fail(Failure.DISCONNECTED, "camera Wi-Fi network lost")
                    }
                }
            }
        }
        setStage(Stage.WIFI_CONFIRMATION)
        if (!active) return
        debugLog("Requesting WifiNetworkSpecifier (withBssid=${!bssid.isNullOrBlank()}, security=$security)")
        CameraDiagnostics.breadcrumb(
            stage = "wifiRequest",
            message = "Requesting camera Wi-Fi network",
            context = mapOf(
                "withBssid" to (!bssid.isNullOrBlank()).toString(),
                "security" to security.name,
                "isRetry" to isRetry.toString(),
            ),
        )
        try {
            handle = platform.requestWifiNetwork(name, password, bssid, security, callbacks)
            networkHandle = handle
        } catch (_: SecurityException) {
            fail(Failure.PERMISSION, "requestWifiNetwork SecurityException")
            return
        } catch (_: IllegalArgumentException) {
            fail(Failure.WIFI, "requestWifiNetwork IllegalArgumentException")
            return
        }
        if (active && stage == Stage.WIFI_CONFIRMATION && cameraNetwork == null && networkHandle === handle) {
            val timeoutGeneration = generation
            wifiRequestTimeout = Runnable {
                if (timeoutGeneration == generation && active && stage == Stage.WIFI_CONFIRMATION && cameraNetwork == null) {
                    debugLog("WifiNetworkSpecifier request timed out")
                    fail(Failure.WIFI, "WifiNetworkSpecifier request timed out")
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
        val gateway = platform.defaultIpv4Gateway(properties)
        debugLog("inspectNetwork hasGateway=${gateway != null}")
        CameraDiagnostics.breadcrumb(
            stage = "networkInspect",
            message = "Inspected camera Wi-Fi network properties",
            context = mapOf(
                "hasGateway" to (gateway != null).toString(),
                "stage" to (stage?.name ?: "NONE"),
            ),
        )
        gateway ?: return
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
        debugLog("Stage -> $value")
        CameraDiagnostics.breadcrumb(
            stage = "stageChanged",
            message = "Camera connection stage changed",
            context = mapOf("stage" to value.name),
        )
        listener.onStage(value)
    }

    private fun startBleTimeout(timeoutMs: Long = BLE_TIMEOUT_MS) {
        cancelBleTimeout()
        val current = generation
        bleTimeout = Runnable {
            if (current != generation || !active) return@Runnable
            when (stage) {
                Stage.PAIRING -> fail(Failure.PAIRING, "BLE pairing timeout")
                Stage.BLUETOOTH -> fail(Failure.BLUETOOTH, "BLE connection timeout")
                Stage.WIFI_STARTING -> fail(Failure.WIFI, "camera Wi-Fi start timeout")
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

    private fun fail(reason: Failure, detail: String? = null) {
        if (!active) return
        val failedStage = stage
        debugLog("Connection failed reason=$reason stage=$failedStage detail=$detail")
        CameraDiagnostics.failure(
            stage = "bleWifiConnection",
            reason = reason.name,
            detail = detail,
            context = mapOf("stage" to (failedStage?.name ?: "NONE")),
        )
        active = false
        releaseResources()
        listener.onFailure(reason)
    }

    private fun releaseResources() {
        scanning = false
        bleScanTimeout?.let(platform::removeCallbacks)
        bleScanTimeout = null
        gattRetryRunnable?.let(platform::removeCallbacks)
        gattRetryRunnable = null
        cancelBleTimeout()
        cancelWifiScanTimeout()
        cancelWifiRequestTimeout()
        stopBleScan()
        unregisterBondReceiver()
        unregisterWifiReceiver()
        wifiCredentialsReady = false
        gattConnectAttempts = 0
        gattConnected = false
        deviceBonded = false
        gattServicesDiscovered = false
        negotiatedMtu = 0
        usingPreBondGatt = false
        retriedPostBondGatt = false
        pendingSSID = null
        pendingPassword = null
        activeWifiCapabilities = ""
        activeWifiSecurity = WifiSecurity.WPA2
        retriedWpa3 = false
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
                        deviceBonded = true
                        unregisterBondReceiver()
                        val currentGatt = gatt
                        val reuseGatt = currentGatt != null && gattConnected && gattServicesDiscovered && negotiatedMtu >= 67
                        CameraDiagnostics.breadcrumb(
                            stage = "bleBondState",
                            message = "Bluetooth bond established",
                            context = mapOf(
                                "bondState" to "BOND_BONDED",
                                "reuseGatt" to reuseGatt.toString(),
                            ),
                        )
                        setStage(Stage.BLUETOOTH)
                        if (!active) return@registerBondReceiver
                        if (reuseGatt) {
                            usingPreBondGatt = true
                            proceedAfterBondedAndDiscovered(currentGatt!!)
                        } else {
                            closeGatt()
                            gattConnectAttempts = 0
                            openGatt()
                        }
                    }
                    BluetoothDevice.BOND_BONDING -> {
                        CameraDiagnostics.breadcrumb(
                            stage = "bleBondState",
                            message = "Bluetooth bonding in progress",
                            context = mapOf("bondState" to "BOND_BONDING"),
                        )
                    }
                    BluetoothDevice.BOND_NONE -> {
                        CameraDiagnostics.breadcrumb(
                            stage = "bleBondState",
                            message = "Bluetooth bond ended in BOND_NONE",
                            level = "warn",
                            context = mapOf("bondState" to "BOND_NONE"),
                        )
                        fail(Failure.PAIRING, "bond state transitioned to BOND_NONE")
                    }
                }
            }
            true
        } catch (_: Exception) {
            fail(Failure.PAIRING, "registerBondReceiver failed")
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
            wifiReceiverHandle = platform.registerWifiScanReceiver { updated ->
                if (expectedGeneration != generation || !active || pendingSSID == null) return@registerWifiScanReceiver
                debugLog("Wi-Fi scan broadcast updated=$updated")
                findFreshAccessPoint()
                if (active && pendingSSID != null && !updated) {
                    fallbackToSsidOnlyWifi()
                }
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
                override fun onScanFailed(errorCode: Int) {
                    debugLog("BLE scan failed errorCode=$errorCode")
                    onFailed(errorCode)
                }
            }
            val settings = ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                .build()
            scanner.startScan(null, settings, callback)
            debugLog("BLE scan started (LOW_LATENCY)")
            connectedSonyEntries().forEach(onEntry)
            return object : Handle {
                override fun close() {
                    scanner.stopScan(callback)
                }
            }
        }

        private fun connectedSonyEntries(): List<BleScanEntry> {
            val manager = bluetoothManager ?: return emptyList()
            val connected = LinkedHashMap<String, BluetoothDevice>()
            for (profile in intArrayOf(BluetoothProfile.GATT, BluetoothProfile.GATT_SERVER)) {
                val devices = try {
                    manager.getConnectedDevices(profile)
                } catch (_: SecurityException) {
                    emptyList()
                }
                devices.forEach { device ->
                    connected.putIfAbsent(device.address.uppercase(Locale.ROOT), device)
                }
            }
            val matched = connected.values.mapNotNull { device ->
                val name = try { device.name } catch (_: SecurityException) { null }
                val uuids = try { device.uuids?.map { it.uuid }.orEmpty() } catch (_: SecurityException) { emptyList() }
                val isSony = CONTROL_SERVICE in uuids || PAIRING_SERVICE in uuids || isSonyCameraBleName(name)
                if (!isSony) return@mapNotNull null
                val bonded = try { device.bondState == BluetoothDevice.BOND_BONDED } catch (_: SecurityException) { false }
                BleScanEntry(
                    id = device.address,
                    name = name?.takeIf { it.isNotBlank() } ?: SONY_CAMERA_LABEL,
                    isSony = true,
                    isBonded = bonded,
                    connectGatt = { cb -> connectAndroidGatt(device, cb) },
                    createBond = { device.createBond() },
                )
            }
            debugLog("Connected GATT devices checked total=${connected.size} matchedSony=${matched.size}")
            return matched
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
                override fun onCharacteristicRead(
                    source: BluetoothGatt,
                    item: BluetoothGattCharacteristic,
                    value: ByteArray,
                    status: Int,
                ) {
                    callback.onCharacteristicRead(handle, item.uuid, value, status)
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
                    val prevBondState = intent.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, BluetoothDevice.BOND_NONE)
                    if (bondState == BluetoothDevice.BOND_NONE && prevBondState == BluetoothDevice.BOND_NONE) return
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
            wifi?.scanResults.orEmpty().map { WifiApResult(it.SSID, it.BSSID, it.timestamp, it.capabilities.orEmpty()) }

        override fun registerWifiScanReceiver(onScanResults: (updated: Boolean) -> Unit): Handle {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    if (intent.action == WifiManager.SCAN_RESULTS_AVAILABLE_ACTION) {
                        val updated = intent.getBooleanExtra(WifiManager.EXTRA_RESULTS_UPDATED, true)
                        onScanResults(updated)
                    }
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
            bssid: String?,
            callbacks: WifiNetworkCallbacks,
        ): Handle = requestWifiNetwork(ssid, password, bssid, WifiSecurity.WPA2, callbacks)

        override fun requestWifiNetwork(
            ssid: String,
            password: String,
            bssid: String?,
            security: WifiSecurity,
            callbacks: WifiNetworkCallbacks,
        ): Handle {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                throw UnsupportedOperationException("WifiNetworkSpecifier requires Android 10+")
            }
            val manager = checkNotNull(connectivity)
            val specifier = WifiNetworkSpecifier.Builder()
                .setSsid(ssid)
                .apply {
                    if (!bssid.isNullOrBlank()) setBssid(MacAddress.fromString(bssid))
                    when (security) {
                        WifiSecurity.WPA3 -> setWpa3Passphrase(password)
                        WifiSecurity.WPA2 -> setWpa2Passphrase(password)
                    }
                }
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
            val selector = ManualWifiSelector()
            val networkStates = LinkedHashMap<String, Pair<Network, LinkProperties>>()
            var evalRunnable: Runnable? = null
            var closed = false

            fun cancelPendingEval() {
                evalRunnable?.let(main::removeCallbacks)
                evalRunnable = null
            }

            fun evaluate() {
                if (closed) return
                cancelPendingEval()
                val nowMs = SystemClock.elapsedRealtime()
                val selected = selector.pollSelected(nowMs)
                if (selected != null) {
                    val (observation, identity) = selected
                    val pair = networkStates[observation.networkKey] ?: return
                    callbacks.onLegacyNetworkReady(pair.first, identity, pair.second)
                    return
                }
                val delayMs = selector.nextEvaluationDelayMs(nowMs) ?: return
                val runnable = Runnable { evaluate() }
                evalRunnable = runnable
                main.postDelayed(runnable, delayMs)
            }

            class ManualWifiCallback : ConnectivityManager.NetworkCallback {
                constructor() : super()
                @androidx.annotation.RequiresApi(Build.VERSION_CODES.S)
                constructor(flags: Int) : super(flags)

                private val capabilitiesByNetwork = mutableMapOf<Network, NetworkCapabilities>()
                private val propertiesByNetwork = mutableMapOf<Network, LinkProperties>()

                @Suppress("DEPRECATION")
                private fun inspect(network: Network) {
                    if (Build.VERSION.SDK_INT < 29 || closed) return
                    val capabilities = capabilitiesByNetwork[network] ?: return
                    val properties = propertiesByNetwork[network] ?: return
                    if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return
                    val info = capabilities.transportInfo as? WifiInfo
                    var ssid = info?.ssid
                    var bssid = info?.bssid
                    // 旧系统没有位置回调标志；仅当回调无 SSID/BSSID 且为 Android 11 及以下时参考连接信息。
                    if (ssid.isNullOrBlank() && bssid.isNullOrBlank() && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                        val legacy = wifi?.connectionInfo
                        ssid = legacy?.ssid
                        bssid = legacy?.bssid
                    }
                    val gateway = defaultIpv4Gateway(properties)
                    val validated = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                    val key = network.toString()
                    debugLog(
                        "ManualWifiCallback.inspect key=$key validated=$validated " +
                            "hasGateway=${gateway != null} strictId=${SonyCameraModel.networkIdentity(ssid, bssid) != null}",
                    )
                    networkStates[key] = network to properties
                    selector.update(
                        ManualWifiObservation(
                            networkKey = key,
                            ssid = ssid,
                            bssid = bssid,
                            gateway = gateway,
                            validated = validated,
                        ),
                        nowMs = SystemClock.elapsedRealtime(),
                    )
                    evaluate()
                }

                override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                    main.post {
                        capabilitiesByNetwork[network] = capabilities
                        inspect(network)
                    }
                }
                override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
                    main.post {
                        propertiesByNetwork[network] = properties
                        inspect(network)
                    }
                }
                override fun onLost(network: Network) {
                    main.post {
                        capabilitiesByNetwork.remove(network)
                        propertiesByNetwork.remove(network)
                        val key = network.toString()
                        networkStates.remove(key)
                        selector.remove(key)
                        callbacks.onLost(network)
                        evaluate()
                    }
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
                override fun close() {
                    main.post {
                        closed = true
                        cancelPendingEval()
                        networkStates.clear()
                    }
                    manager.unregisterNetworkCallback(callback)
                }
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

        private fun propertiesLabel(properties: Int): String = buildString {
            if (properties and BluetoothGattCharacteristic.PROPERTY_READ != 0) append('R')
            if (properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0) append('W')
            if (properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0) append('w')
            if (properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) append('N')
            if (properties and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0) append('I')
        }

        override fun sonyServiceSummary(): String {
            val sonyServices = source.services.orEmpty().filter {
                it.uuid.toString().lowercase(Locale.ROOT).startsWith("8000")
            }
            if (sonyServices.isEmpty()) return "none"
            return sonyServices.joinToString(",") { service ->
                val prefix = service.uuid.toString().substring(0, 8).lowercase(Locale.ROOT)
                val chars = service.characteristics.orEmpty().joinToString(",") { item ->
                    val flags = propertiesLabel(item.properties)
                    if (flags.isEmpty()) shortUuid(item.uuid) else "${shortUuid(item.uuid)}($flags)"
                }
                "$prefix:[$chars]"
            }
        }

        @Suppress("DEPRECATION")
        private fun writeDefault(item: BluetoothGattCharacteristic, value: ByteArray): Boolean {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                return source.writeCharacteristic(
                    item,
                    value,
                    BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
                ) == BluetoothStatusCodes.SUCCESS
            }
            item.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            item.value = value
            return source.writeCharacteristic(item)
        }

        override fun writePairingInit(): Boolean {
            val pairing = characteristic(PAIRING_SERVICE, PAIRING_INIT_CHARACTERISTIC) ?: return false
            return writeDefault(pairing, byteArrayOf(6, 8, 1, 0, 0, 0, 0))
        }

        override fun writeWifiOn(): Boolean {
            val command = characteristic(CONTROL_SERVICE, WIFI_ON_CHARACTERISTIC) ?: return false
            return writeDefault(command, byteArrayOf(1))
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

private val SAE_CAPABILITY_REGEX = Regex("(^|[^A-Z0-9])SAE([^A-Z0-9]|$)")
private val PSK_CAPABILITY_REGEX = Regex("(^|[^A-Z0-9])PSK([^A-Z0-9]|$)")

internal fun advertisesWpa3Sae(capabilities: String?): Boolean {
    val upper = capabilities.orEmpty().uppercase(Locale.ROOT)
    return SAE_CAPABILITY_REGEX.containsMatchIn(upper)
}

internal fun selectWifiSecurity(capabilities: String?): SonyCameraConnection.WifiSecurity {
    val upper = capabilities.orEmpty().uppercase(Locale.ROOT)
    val hasSae = SAE_CAPABILITY_REGEX.containsMatchIn(upper)
    val hasPsk = PSK_CAPABILITY_REGEX.containsMatchIn(upper)
    return if (hasSae && !hasPsk) {
        SonyCameraConnection.WifiSecurity.WPA3
    } else {
        SonyCameraConnection.WifiSecurity.WPA2
    }
}

internal data class Ipv4RouteCandidate(
    val isDefaultRoute: Boolean,
    val hasGateway: Boolean,
    val gateway: Inet4Address?,
    val destinationPrefixLength: Int,
)

internal data class Ipv4LinkCandidate(
    val address: Inet4Address,
    val prefixLength: Int,
)

internal fun resolveCameraIpv4Gateway(
    routes: List<Ipv4RouteCandidate>,
    dhcpServerAddress: Inet4Address?,
    linkAddresses: List<Ipv4LinkCandidate>,
    dnsServers: List<Inet4Address>,
): Inet4Address? {
    val ownInts = linkAddresses.mapTo(HashSet()) { ipv4ToInt(it.address) }
    routes.asSequence()
        .filter { it.isDefaultRoute }
        .mapNotNull { it.gateway }
        .firstOrNull { isUsableIpv4Gateway(it, ownInts, requirePrivate = false) }
        ?.let { return it }

    dhcpServerAddress
        ?.takeIf { isUsableIpv4Gateway(it, ownInts, requirePrivate = false) }
        ?.let { return it }

    routes.asSequence()
        .filter { !it.isDefaultRoute && (it.hasGateway || it.gateway != null) }
        .sortedBy { it.destinationPrefixLength }
        .mapNotNull { it.gateway }
        .firstOrNull { isUsableIpv4Gateway(it, ownInts, requirePrivate = true) }
        ?.let { return it }

    dnsServers.asSequence()
        .firstOrNull { dns ->
            isUsableIpv4Gateway(dns, ownInts, requirePrivate = true) &&
                linkAddresses.any { link -> sameIpv4Subnet(dns, link.address, link.prefixLength) }
        }
        ?.let { return it }

    for (link in linkAddresses) {
        if (!link.address.isSiteLocalAddress || link.prefixLength !in 16..30) continue
        val ownInt = ipv4ToInt(link.address)
        val mask = (-1L shl (32 - link.prefixLength)).toInt()
        val firstHostInt = (ownInt and mask) or 1
        if (firstHostInt != ownInt && firstHostInt !in ownInts) {
            return intToIpv4(firstHostInt)
        }
    }
    return null
}

private fun isUsableIpv4Gateway(
    candidate: Inet4Address?,
    ownInts: Set<Int>,
    requirePrivate: Boolean,
): Boolean {
    candidate ?: return false
    if (candidate.isAnyLocalAddress || candidate.isLoopbackAddress || candidate.isMulticastAddress) return false
    if (ipv4ToInt(candidate) in ownInts) return false
    if (requirePrivate && !(candidate.isSiteLocalAddress || candidate.isLinkLocalAddress)) return false
    return true
}

private fun sameIpv4Subnet(a: Inet4Address, b: Inet4Address, prefixLength: Int): Boolean {
    if (prefixLength <= 0) return true
    if (prefixLength >= 32) return ipv4ToInt(a) == ipv4ToInt(b)
    val mask = (-1L shl (32 - prefixLength)).toInt()
    return (ipv4ToInt(a) and mask) == (ipv4ToInt(b) and mask)
}

private fun ipv4ToInt(address: Inet4Address): Int {
    val bytes = address.address
    return ((bytes[0].toInt() and 0xFF) shl 24) or
        ((bytes[1].toInt() and 0xFF) shl 16) or
        ((bytes[2].toInt() and 0xFF) shl 8) or
        (bytes[3].toInt() and 0xFF)
}

private fun intToIpv4(value: Int): Inet4Address {
    val bytes = byteArrayOf(
        ((value ushr 24) and 0xFF).toByte(),
        ((value ushr 16) and 0xFF).toByte(),
        ((value ushr 8) and 0xFF).toByte(),
        (value and 0xFF).toByte(),
    )
    return InetAddress.getByAddress(bytes) as Inet4Address
}

internal fun cleanWifiSsid(raw: String?): String? {
    val cleaned = raw?.trim()?.removeSurrounding("\"")?.trim().orEmpty()
    if (cleaned.isEmpty() || cleaned.equals("<unknown ssid>", ignoreCase = true)) return null
    return cleaned
}

internal data class ManualWifiObservation(
    val networkKey: String,
    val ssid: String?,
    val bssid: String?,
    val gateway: Inet4Address?,
    val validated: Boolean,
) {
    val isDirectSsid: Boolean
        get() = cleanWifiSsid(ssid)?.startsWith("DIRECT-", ignoreCase = true) == true

    val strictIdentity: String?
        get() = SonyCameraModel.networkIdentity(ssid, bssid)

    fun fallbackIdentity(): String? {
        strictIdentity?.let { return it }
        cleanWifiSsid(ssid)?.let { return "sony-wifi-ssid:$it" }
        gateway?.hostAddress?.takeIf { it.isNotBlank() }?.let { return "sony-wifi-route:$it" }
        return null
    }
}

internal class ManualWifiSelector(
    private val dualWlanSettleDelayMs: Long = 400L,
    private val bssidGraceDelayMs: Long = 2_000L,
) {
    private data class Entry(
        val observation: ManualWifiObservation,
        val firstSeenMs: Long,
    )

    private val entries = LinkedHashMap<String, Entry>()

    fun update(observation: ManualWifiObservation, nowMs: Long) {
        val previous = entries[observation.networkKey]
        val firstSeen = previous?.firstSeenMs ?: nowMs
        entries[observation.networkKey] = Entry(observation, firstSeen)
    }

    fun remove(networkKey: String) {
        entries.remove(networkKey)
    }

    fun nextEvaluationDelayMs(nowMs: Long): Long? {
        val readyAt = readyTimestampMs() ?: return null
        return maxOf(0L, readyAt - nowMs)
    }

    fun pollSelected(nowMs: Long): Pair<ManualWifiObservation, String>? {
        val best = bestEntry() ?: return null
        val readyAt = readyTimestampMsFor(best) ?: return null
        if (nowMs < readyAt) return null
        val allowFallback = nowMs - best.firstSeenMs >= bssidGraceDelayMs
        val identity = best.observation.strictIdentity
            ?: if (allowFallback) best.observation.fallbackIdentity() else null
        return identity?.let { best.observation to it }
    }

    private fun bestEntry(): Entry? = entries.values
        .asSequence()
        .filter { it.observation.gateway != null }
        .maxWithOrNull(
            compareBy<Entry> { rank(it.observation) }
                .thenBy { if (it.observation.strictIdentity != null) 1 else 0 }
                .thenBy { -it.firstSeenMs },
        )

    private fun rank(observation: ManualWifiObservation): Int = when {
        observation.isDirectSsid && !observation.validated -> 3
        !observation.validated -> 2
        observation.isDirectSsid -> 1
        else -> 0
    }

    private fun readyTimestampMs(): Long? = bestEntry()?.let(::readyTimestampMsFor)

    private fun readyTimestampMsFor(best: Entry): Long? {
        val obs = best.observation
        if (obs.gateway == null) return null
        if (obs.isDirectSsid && !obs.validated && obs.strictIdentity != null) {
            return best.firstSeenMs
        }
        val bssidWait = if (obs.strictIdentity != null) 0L else bssidGraceDelayMs
        val dualWait = if (obs.isDirectSsid && !obs.validated) 0L else dualWlanSettleDelayMs
        return best.firstSeenMs + maxOf(bssidWait, dualWait)
    }
}

private val SONY_CAMERA_BLE_NAME_PREFIXES = listOf("ILCE-", "ILME-", "ZV-", "DSC-", "SLT-", "NEX-")

internal fun isSonyCameraBleName(name: String?): Boolean {
    val trimmed = name?.trim()?.takeIf { it.isNotEmpty() } ?: return false
    if (SonyCameraModel.fromAdvertisement(trimmed) != SonyCameraModel.UNKNOWN) return true
    val upper = trimmed.uppercase(Locale.ROOT)
    return SONY_CAMERA_BLE_NAME_PREFIXES.any { prefix -> upper.startsWith(prefix) }
}
