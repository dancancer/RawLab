package com.rawlab.android.camera

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.net.LinkProperties
import android.net.Network
import com.rawlab.android.R
import com.rawlab.android.diagnostics.DiagnosticEnvironmentInfo
import com.rawlab.android.diagnostics.DiagnosticSessionStore
import com.rawlab.android.editor.TestEditorApplication
import org.junit.Assert.*
import org.junit.Test
import java.net.Inet4Address
import java.net.InetAddress
import java.nio.file.Files
import java.util.PriorityQueue
import java.util.UUID

class SonyCameraConnectionTest {
    private class FakePlatform : SonyCameraConnection.Platform {
        private data class ScheduledTask(val runAtMs: Long, val seq: Long, val action: Runnable) : Comparable<ScheduledTask> {
            override fun compareTo(other: ScheduledTask): Int =
                compareValuesBy(this, other, { it.runAtMs }, { it.seq })
        }

        private var nowMs = 10_000L
        private var seq = 0L
        private val queue = PriorityQueue<ScheduledTask>()
        private val activeActions = mutableSetOf<Runnable>()

        override var sdkInt: Int = 34
        override fun isMainThread(): Boolean = true
        override fun post(action: Runnable) {
            activeActions += action
            queue += ScheduledTask(nowMs, seq++, action)
        }
        override fun postDelayed(action: Runnable, delayMs: Long) {
            activeActions += action
            queue += ScheduledTask(nowMs + delayMs, seq++, action)
        }
        override fun removeCallbacks(action: Runnable) {
            activeActions -= action
        }
        override fun elapsedMicros(): Long = nowMs * 1_000L
        override fun hasPermissions(permissions: List<String>): Boolean = true
        override fun isBluetoothPresent(): Boolean = true
        override fun isBluetoothEnabled(): Boolean = true
        override fun isLocationEnabled(): Boolean = true

        var onScanEntry: ((SonyCameraConnection.BleScanEntry) -> Unit)? = null
        var scanStopped = false
        override fun startBleScan(
            onEntry: (SonyCameraConnection.BleScanEntry) -> Unit,
            onFailed: (Int) -> Unit,
        ): SonyCameraConnection.Handle {
            onScanEntry = onEntry
            return object : SonyCameraConnection.Handle {
                override fun close() { scanStopped = true }
            }
        }

        var onBondChangedCallback: ((String, Int) -> Unit)? = null
        var bondReceiverClosed = false
        override fun registerBondReceiver(onBondChanged: (String, Int) -> Unit): SonyCameraConnection.Handle {
            onBondChangedCallback = onBondChanged
            bondReceiverClosed = false
            return object : SonyCameraConnection.Handle {
                override fun close() {
                    bondReceiverClosed = true
                    if (onBondChangedCallback === onBondChanged) onBondChangedCallback = null
                }
            }
        }

        var wifiScanReturn = true
        var scanResultsList: List<SonyCameraConnection.WifiApResult> = emptyList()
        var wifiReceiverClosed = false
        var onWifiScanCallback: ((Boolean) -> Unit)? = null
        override fun isWifiAvailable(): Boolean = true
        override fun startWifiScan(): Boolean = wifiScanReturn
        override fun wifiScanResults(): List<SonyCameraConnection.WifiApResult> = scanResultsList
        override fun registerWifiScanReceiver(onScanResults: (updated: Boolean) -> Unit): SonyCameraConnection.Handle {
            onWifiScanCallback = onScanResults
            wifiReceiverClosed = false
            return object : SonyCameraConnection.Handle {
                override fun close() { wifiReceiverClosed = true }
            }
        }

        var requestedSsid: String? = null
        var requestedPassword: String? = null
        var requestedBssid: String? = null
        var requestedSecurity: SonyCameraConnection.WifiSecurity? = null
        val requestedSecurities = mutableListOf<SonyCameraConnection.WifiSecurity>()
        var activeWifiCallbacks: SonyCameraConnection.WifiNetworkCallbacks? = null
        var networkHandleClosed = false
        var manualWifiCallbacks: SonyCameraConnection.LegacyWifiCallbacks? = null
        var manualWifiHandleClosed = false
        var gatewayForProperties: (LinkProperties?) -> Inet4Address? = { null }

        override fun isConnectivityAvailable(): Boolean = true
        override fun requestWifiNetwork(
            ssid: String,
            password: String,
            bssid: String?,
            callbacks: SonyCameraConnection.WifiNetworkCallbacks,
        ): SonyCameraConnection.Handle = requestWifiNetwork(ssid, password, bssid, SonyCameraConnection.WifiSecurity.WPA2, callbacks)

        override fun requestWifiNetwork(
            ssid: String,
            password: String,
            bssid: String?,
            security: SonyCameraConnection.WifiSecurity,
            callbacks: SonyCameraConnection.WifiNetworkCallbacks,
        ): SonyCameraConnection.Handle {
            requestedSsid = ssid
            requestedPassword = password
            requestedBssid = bssid
            requestedSecurity = security
            requestedSecurities += security
            activeWifiCallbacks = callbacks
            networkHandleClosed = false
            return object : SonyCameraConnection.Handle {
                override fun close() { networkHandleClosed = true }
            }
        }

        override fun registerManualWifiNetwork(callbacks: SonyCameraConnection.LegacyWifiCallbacks): SonyCameraConnection.Handle {
            manualWifiCallbacks = callbacks
            manualWifiHandleClosed = false
            return object : SonyCameraConnection.Handle {
                override fun close() { manualWifiHandleClosed = true }
            }
        }

        override fun defaultIpv4Gateway(properties: LinkProperties?): Inet4Address? = gatewayForProperties(properties)

        fun drain() {
            while (true) {
                val head = queue.peek() ?: break
                if (head.runAtMs > nowMs) break
                queue.poll()
                if (activeActions.remove(head.action)) {
                    head.action.run()
                }
            }
        }

        fun advanceBy(ms: Long) {
            val target = nowMs + ms
            while (true) {
                val next = queue.peek() ?: break
                if (next.runAtMs > target) break
                queue.poll()
                if (activeActions.remove(next.action)) {
                    nowMs = maxOf(nowMs, next.runAtMs)
                    next.action.run()
                }
            }
            nowMs = target
        }

        fun pendingDelayCount(): Int = activeActions.size
    }

    private class FakeGatt(
        override val address: String = "AA:BB:CC:DD:EE:FF",
        private val requiredCharacteristics: Boolean = true,
        private val wifiOnCharacteristic: Boolean = requiredCharacteristics,
        private val mtuResult: Int = 158,
        private val mtuStatus: Int = BluetoothGatt.GATT_SUCCESS,
        private val requestMtuReturn: Boolean = true,
        private val pairingInitStatus: Int = BluetoothGatt.GATT_SUCCESS,
        private val serviceSummary: String = if (requiredCharacteristics) "8000cc00:[cc06,cc07,cc08],8000ee00:[ee01]" else "none",
    ) : SonyCameraConnection.GattHandle {
        var callback: SonyCameraConnection.GattClientCallback? = null
        var disconnected = false
        var closed = false
        var discoverServicesCalls = 0
        var writePairingInitCalled = false
        var writeWifiOnCalled = false
        var readSsidCalled = false
        override fun requestMtu(mtu: Int): Boolean {
            if (!requestMtuReturn) return false
            callback?.onMtuChanged(this, mtuResult, mtuStatus)
            return true
        }
        override fun discoverServices(): Boolean {
            discoverServicesCalls++
            callback?.onServicesDiscovered(this, BluetoothGatt.GATT_SUCCESS)
            return true
        }
        override fun hasRequiredCharacteristics(): Boolean = requiredCharacteristics
        override fun hasWifiOnCharacteristic(): Boolean = wifiOnCharacteristic
        override fun sonyServiceSummary(): String = serviceSummary
        override fun writePairingInit(): Boolean {
            writePairingInitCalled = true
            callback?.onCharacteristicWrite(this, UUID.fromString("0000ee01-0000-1000-8000-00805f9b34fb"), pairingInitStatus)
            return true
        }
        override fun writeWifiOn(): Boolean {
            writeWifiOnCalled = true
            return true
        }
        override fun readSsid(): Boolean {
            readSsidCalled = true
            return true
        }
        override fun readPassword(): Boolean = true
        override fun disconnect() { disconnected = true }
        override fun close() { closed = true }
    }

    private class RecordingListener : SonyCameraConnection.Listener {
        val stages = mutableListOf<SonyCameraConnection.Stage>()
        val failures = mutableListOf<SonyCameraConnection.Failure>()
        val connected = mutableListOf<Triple<Network, InetAddress, String>>()
        var manualWifiFallbackCount = 0
        override fun onCandidates(items: List<CameraCandidate>) = Unit
        override fun onStage(stage: SonyCameraConnection.Stage) { stages += stage }
        override fun onManualWifiFallback() { manualWifiFallbackCount++ }
        override fun onConnected(network: Network, address: InetAddress, cameraId: String) {
            connected += Triple(network, address, cameraId)
        }
        override fun onFailure(reason: SonyCameraConnection.Failure) { failures += reason }
    }

    private fun stubNetwork(): Network {
        val unsafeClass = Class.forName("sun.misc.Unsafe")
        val field = unsafeClass.getDeclaredField("theUnsafe").apply { isAccessible = true }
        val unsafe = field.get(null)!!
        return unsafeClass.getMethod("allocateInstance", Class::class.java).invoke(unsafe, Network::class.java) as Network
    }

    private fun stubLinkProperties(): LinkProperties {
        val unsafeClass = Class.forName("sun.misc.Unsafe")
        val field = unsafeClass.getDeclaredField("theUnsafe").apply { isAccessible = true }
        val unsafe = field.get(null)!!
        return unsafeClass.getMethod("allocateInstance", Class::class.java).invoke(unsafe, LinkProperties::class.java) as LinkProperties
    }

    private fun createConnection(
        platform: FakePlatform,
        listener: RecordingListener,
        wifiStartingTimeoutMs: Long = 45_000L,
        wifiRequestTimeoutMs: Long = 60_000L,
        wifiScanFallbackMs: Long = 4_000L,
        manualWifiTimeoutMs: Long = 15_000L,
    ): Pair<SonyCameraConnection, Context> {
        val root = Files.createTempDirectory("sony-conn-test").toFile()
        val app = TestEditorApplication(root)
        val conn = SonyCameraConnection(
            app,
            listener,
            platform,
            wifiStartingTimeoutMs,
            wifiRequestTimeoutMs,
            wifiScanFallbackMs,
            manualWifiTimeoutMs,
        )
        return conn to app
    }

    private fun advanceToWifiStarting(
        conn: SonyCameraConnection,
        platform: FakePlatform,
        gatt: FakeGatt,
    ) {
        conn.scan()
        platform.drain()
        platform.onScanEntry?.invoke(
            SonyCameraConnection.BleScanEntry(
                id = gatt.address,
                name = "ILCE-7CM2",
                isSony = true,
                isBonded = true,
                connectGatt = { cb -> gatt.callback = cb; gatt },
                createBond = { true },
            ),
        )
        platform.drain()
        conn.connect(gatt.address)
        platform.drain()
        gatt.callback!!.onConnectionStateChange(gatt, BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_CONNECTED)
        platform.drain()
    }

    private fun sonyCharacteristicValue(text: String): ByteArray {
        val bytes = text.toByteArray(Charsets.US_ASCII)
        return byteArrayOf((bytes.size + 2).toByte(), 0, 0) + bytes
    }

    private fun deliverCredentials(platform: FakePlatform, gatt: FakeGatt) {
        gatt.callback!!.onCharacteristicWrite(gatt, UUID.fromString("0000cc08-0000-1000-8000-00805f9b34fb"), BluetoothGatt.GATT_SUCCESS)
        platform.advanceBy(3_000L)
        gatt.callback!!.onCharacteristicRead(
            gatt,
            UUID.fromString("0000cc06-0000-1000-8000-00805f9b34fb"),
            sonyCharacteristicValue("DIRECT-x123:ILCE-7CM2"),
            BluetoothGatt.GATT_SUCCESS,
        )
        platform.drain()
        gatt.callback!!.onCharacteristicRead(
            gatt,
            UUID.fromString("0000cc07-0000-1000-8000-00805f9b34fb"),
            sonyCharacteristicValue("secretpass"),
            BluetoothGatt.GATT_SUCCESS,
        )
        platform.drain()
    }

    @Test
    fun bleDisconnectAfterCredentialsDoesNotFailWifiConfirmationOrNetwork() {
        val platform = FakePlatform()
        val listener = RecordingListener()
        val gatt = FakeGatt()
        val (conn, _) = createConnection(platform, listener)

        advanceToWifiStarting(conn, platform, gatt)
        val ap = SonyCameraConnection.WifiApResult("DIRECT-x123:ILCE-7CM2", "02:11:22:33:44:55", platform.elapsedMicros() + 3_000_000L)
        platform.scanResultsList = listOf(ap)

        deliverCredentials(platform, gatt)

        // waitForAccessPoint closes GATT and transitions to WIFI_CONFIRMATION once fresh AP is found.
        assertTrue("GATT must be disconnected and closed once Wi-Fi credentials are read", gatt.disconnected && gatt.closed)
        assertEquals(SonyCameraConnection.Stage.WIFI_CONFIRMATION, listener.stages.last())
        assertTrue(listener.failures.isEmpty())

        // Late BLE disconnect callback during WIFI_CONFIRMATION must not fail or tear down networkCallback.
        gatt.callback!!.onConnectionStateChange(gatt, BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_DISCONNECTED)
        platform.drain()
        assertTrue(listener.failures.isEmpty())
        assertFalse(platform.networkHandleClosed)

        // Connect Wi-Fi to Stage.NETWORK, then simulate another BLE disconnect: Wi-Fi transfer stays intact.
        val network = stubNetwork()
        val props = stubLinkProperties()
        val gateway = InetAddress.getByName("192.168.122.1") as Inet4Address
        platform.gatewayForProperties = { gateway }
        platform.activeWifiCallbacks!!.onAvailable(network, props)
        platform.drain()

        assertEquals(SonyCameraConnection.Stage.NETWORK, listener.stages.last())
        assertEquals(1, listener.connected.size)

        gatt.callback!!.onConnectionStateChange(gatt, 8 /* GATT_CONN_TIMEOUT */, BluetoothProfile.STATE_DISCONNECTED)
        platform.drain()
        assertTrue(listener.failures.isEmpty())
        assertFalse(platform.networkHandleClosed)
        conn.close()
    }

    @Test
    fun bleDisconnectBeforeCredentialsStillFailsWithBluetooth() {
        val platform = FakePlatform()
        val listener = RecordingListener()
        val gatt = FakeGatt()
        val (conn, _) = createConnection(platform, listener)

        advanceToWifiStarting(conn, platform, gatt)
        assertEquals(SonyCameraConnection.Stage.WIFI_STARTING, listener.stages.last())

        // Disconnect BEFORE password is read -> must fail with BLUETOOTH.
        gatt.callback!!.onConnectionStateChange(gatt, BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_DISCONNECTED)
        platform.drain()
        assertEquals(listOf(SonyCameraConnection.Failure.BLUETOOTH), listener.failures)

        // Also verify disconnect during Stage.BLUETOOTH fails with BLUETOOTH.
        val listener2 = RecordingListener()
        val gatt2 = FakeGatt()
        val (conn2, _) = createConnection(platform, listener2)
        conn2.scan()
        platform.drain()
        platform.onScanEntry?.invoke(
            SonyCameraConnection.BleScanEntry(
                id = gatt2.address,
                name = "ILCE-7CM2",
                isSony = true,
                isBonded = true,
                connectGatt = { cb -> gatt2.callback = cb; gatt2 },
                createBond = { true },
            ),
        )
        platform.drain()
        conn2.connect(gatt2.address)
        platform.drain()
        gatt2.callback!!.onConnectionStateChange(gatt2, BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_DISCONNECTED)
        platform.drain()
        assertEquals(listOf(SonyCameraConnection.Failure.BLUETOOTH), listener2.failures)
    }

    @Test
    fun wifiStartingTimeoutFiresFailureWifiAndClosesGattOnStall() {
        val platform = FakePlatform()
        val listener = RecordingListener()
        val gatt = FakeGatt()
        val (conn, _) = createConnection(platform, listener, wifiStartingTimeoutMs = 45_000L)

        advanceToWifiStarting(conn, platform, gatt)
        assertTrue(gatt.writeWifiOnCalled)

        // Before 45s -> still waiting.
        platform.advanceBy(44_999L)
        assertTrue(listener.failures.isEmpty())

        // At 45s -> Stage.WIFI_STARTING times out with Failure.WIFI and closes GATT.
        platform.advanceBy(1L)
        assertEquals(listOf(SonyCameraConnection.Failure.WIFI), listener.failures)
        assertTrue(gatt.disconnected && gatt.closed)
    }

    @Test
    fun requestWifiConfirmationTimeoutFiresFailureWifiAndUnregistersCallback() {
        // Case A: no callbacks at all
        run {
            val platform = FakePlatform()
            val listener = RecordingListener()
            val gatt = FakeGatt()
            val (conn, _) = createConnection(platform, listener, wifiRequestTimeoutMs = 60_000L)

            advanceToWifiStarting(conn, platform, gatt)
            platform.scanResultsList = listOf(
                SonyCameraConnection.WifiApResult(
                    "DIRECT-x123:ILCE-7CM2",
                    "02:11:22:33:44:55",
                    platform.elapsedMicros() + 3_000_000L,
                    capabilities = "[WPA2-PSK-CCMP][ESS]",
                ),
            )
            deliverCredentials(platform, gatt)
            assertEquals(SonyCameraConnection.Stage.WIFI_CONFIRMATION, listener.stages.last())

            platform.advanceBy(59_999L)
            assertTrue(listener.failures.isEmpty())
            assertFalse(platform.networkHandleClosed)

            platform.advanceBy(1L)
            assertEquals(listOf(SonyCameraConnection.Failure.WIFI), listener.failures)
            assertTrue(platform.networkHandleClosed)
        }

        // Case B: onAvailable fires without default IPv4 gateway route
        run {
            val platform = FakePlatform()
            val listener = RecordingListener()
            val gatt = FakeGatt()
            val (conn, _) = createConnection(platform, listener, wifiRequestTimeoutMs = 60_000L)

            advanceToWifiStarting(conn, platform, gatt)
            platform.scanResultsList = listOf(
                SonyCameraConnection.WifiApResult(
                    "DIRECT-x123:ILCE-7CM2",
                    "02:11:22:33:44:55",
                    platform.elapsedMicros() + 3_000_000L,
                    capabilities = "[WPA2-PSK-CCMP][ESS]",
                ),
            )
            deliverCredentials(platform, gatt)
            platform.gatewayForProperties = { null }
            platform.activeWifiCallbacks!!.onAvailable(stubNetwork(), stubLinkProperties())
            platform.drain()
            assertEquals(SonyCameraConnection.Stage.WIFI_CONFIRMATION, listener.stages.last())

            platform.advanceBy(60_000L)
            assertEquals(listOf(SonyCameraConnection.Failure.WIFI), listener.failures)
            assertTrue(platform.networkHandleClosed)
        }
    }

    @Test
    fun requestWifiTimeoutIsCancelledOnNetworkUnavailableAndClose() {
        // 1) Cancelled on Stage.NETWORK
        run {
            val platform = FakePlatform()
            val listener = RecordingListener()
            val gatt = FakeGatt()
            val (conn, _) = createConnection(platform, listener, wifiRequestTimeoutMs = 60_000L)

            advanceToWifiStarting(conn, platform, gatt)
            platform.scanResultsList = listOf(
                SonyCameraConnection.WifiApResult(
                    "DIRECT-x123:ILCE-7CM2",
                    "02:11:22:33:44:55",
                    platform.elapsedMicros() + 3_000_000L,
                    capabilities = "[WPA2-PSK-CCMP][ESS]",
                ),
            )
            deliverCredentials(platform, gatt)
            val gateway = InetAddress.getByName("192.168.122.1") as Inet4Address
            platform.gatewayForProperties = { gateway }
            platform.activeWifiCallbacks!!.onAvailable(stubNetwork(), stubLinkProperties())
            platform.drain()
            assertEquals(SonyCameraConnection.Stage.NETWORK, listener.stages.last())

            platform.advanceBy(120_000L)
            assertTrue("Timeout must not fire after Stage.NETWORK", listener.failures.isEmpty())
            conn.close()
        }

        // 2) Cancelled on onUnavailable()
        run {
            val platform = FakePlatform()
            val listener = RecordingListener()
            val gatt = FakeGatt()
            val (conn, _) = createConnection(platform, listener, wifiRequestTimeoutMs = 60_000L)

            advanceToWifiStarting(conn, platform, gatt)
            platform.scanResultsList = listOf(
                SonyCameraConnection.WifiApResult(
                    "DIRECT-x123:ILCE-7CM2",
                    "02:11:22:33:44:55",
                    platform.elapsedMicros() + 3_000_000L,
                    capabilities = "[WPA2-PSK-CCMP][ESS]",
                ),
            )
            deliverCredentials(platform, gatt)
            platform.activeWifiCallbacks!!.onUnavailable()
            platform.drain()
            assertEquals(listOf(SonyCameraConnection.Failure.WIFI), listener.failures)
            assertEquals(0, platform.pendingDelayCount())
        }

        // 3) Cancelled on close()
        run {
            val platform = FakePlatform()
            val listener = RecordingListener()
            val gatt = FakeGatt()
            val (conn, _) = createConnection(platform, listener, wifiRequestTimeoutMs = 60_000L)

            advanceToWifiStarting(conn, platform, gatt)
            platform.scanResultsList = listOf(
                SonyCameraConnection.WifiApResult(
                    "DIRECT-x123:ILCE-7CM2",
                    "02:11:22:33:44:55",
                    platform.elapsedMicros() + 3_000_000L,
                    capabilities = "[WPA2-PSK-CCMP][ESS]",
                ),
            )
            deliverCredentials(platform, gatt)
            conn.close()
            platform.advanceBy(120_000L)
            assertTrue(listener.failures.isEmpty())
            assertTrue(platform.networkHandleClosed)
            assertEquals(0, platform.pendingDelayCount())
        }
    }

    @Test
    fun wifiStartScanReturningFalseFallsBackToSsidOnlyAndUsesCachedBssidWhenFresh() {
        // Case A: startScan() == false and no fresh AP -> falls back immediately to SSID-only WifiNetworkSpecifier
        run {
            val platform = FakePlatform()
            val listener = RecordingListener()
            val gatt = FakeGatt()
            val (conn, _) = createConnection(platform, listener)

            advanceToWifiStarting(conn, platform, gatt)
            platform.wifiScanReturn = false
            platform.scanResultsList = emptyList()
            deliverCredentials(platform, gatt)

            assertTrue(listener.failures.isEmpty())
            assertEquals(SonyCameraConnection.Stage.WIFI_CONFIRMATION, listener.stages.last())
            assertEquals("DIRECT-x123:ILCE-7CM2", platform.requestedSsid)
            assertNull(platform.requestedBssid)
            assertTrue(platform.wifiReceiverClosed)
            conn.close()
        }

        // Case B: startScan() == false but fresh AP is already cached -> proceeds to WIFI_CONFIRMATION with BSSID
        run {
            val platform = FakePlatform()
            val listener = RecordingListener()
            val gatt = FakeGatt()
            val (conn, _) = createConnection(platform, listener)

            advanceToWifiStarting(conn, platform, gatt)
            platform.wifiScanReturn = false
            platform.scanResultsList = listOf(
                SonyCameraConnection.WifiApResult("DIRECT-x123:ILCE-7CM2", "02:11:22:33:44:55", platform.elapsedMicros() + 3_000_000L),
            )
            deliverCredentials(platform, gatt)

            assertTrue(listener.failures.isEmpty())
            assertEquals(SonyCameraConnection.Stage.WIFI_CONFIRMATION, listener.stages.last())
            assertEquals("DIRECT-x123:ILCE-7CM2", platform.requestedSsid)
            assertEquals("02:11:22:33:44:55", platform.requestedBssid)
            conn.close()
        }
    }

    @Test
    fun wifiScanAbortedBroadcastFallsBackToSsidOnlyWifiSpecifier() {
        val platform = FakePlatform()
        val listener = RecordingListener()
        val gatt = FakeGatt()
        val (conn, _) = createConnection(platform, listener)

        advanceToWifiStarting(conn, platform, gatt)
        platform.wifiScanReturn = true
        platform.scanResultsList = emptyList()
        deliverCredentials(platform, gatt)

        assertEquals(SonyCameraConnection.Stage.WIFI_STARTING, listener.stages.last())
        assertNull(platform.requestedSsid)

        platform.onWifiScanCallback!!.invoke(false)

        assertTrue(listener.failures.isEmpty())
        assertEquals(SonyCameraConnection.Stage.WIFI_CONFIRMATION, listener.stages.last())
        assertEquals("DIRECT-x123:ILCE-7CM2", platform.requestedSsid)
        assertNull(platform.requestedBssid)
        assertTrue(platform.wifiReceiverClosed)
        conn.close()
    }

    @Test
    fun wifiScanFallbackTimerRequestsSsidOnlyWifiSpecifier() {
        val platform = FakePlatform()
        val listener = RecordingListener()
        val gatt = FakeGatt()
        val (conn, _) = createConnection(platform, listener, wifiScanFallbackMs = 4_000L)

        advanceToWifiStarting(conn, platform, gatt)
        platform.wifiScanReturn = true
        platform.scanResultsList = emptyList()
        deliverCredentials(platform, gatt)

        platform.advanceBy(3_999L)
        assertEquals(SonyCameraConnection.Stage.WIFI_STARTING, listener.stages.last())
        assertNull(platform.requestedSsid)

        platform.advanceBy(1L)
        assertTrue(listener.failures.isEmpty())
        assertEquals(SonyCameraConnection.Stage.WIFI_CONFIRMATION, listener.stages.last())
        assertEquals("DIRECT-x123:ILCE-7CM2", platform.requestedSsid)
        assertNull(platform.requestedBssid)

        val network = stubNetwork()
        val gateway = InetAddress.getByName("192.168.122.1") as Inet4Address
        platform.gatewayForProperties = { gateway }
        platform.activeWifiCallbacks!!.onAvailable(network, stubLinkProperties())
        platform.drain()

        assertEquals(SonyCameraConnection.Stage.NETWORK, listener.stages.last())
        assertEquals(1, listener.connected.size)
        conn.close()
    }

    @Test
    fun transientBleEstablishmentFailureRetriesAndRecoversOrFailsAfterLimit() {
        // Part A: attempt 1 fails with status=133 -> retries after 400ms and recovers on attempt 2
        run {
            val platform = FakePlatform()
            val listener = RecordingListener()
            val gatt1 = FakeGatt()
            val gatt2 = FakeGatt()
            var connectCount = 0
            val (conn, _) = createConnection(platform, listener)

            conn.scan()
            platform.drain()
            platform.onScanEntry?.invoke(
                SonyCameraConnection.BleScanEntry(
                    id = gatt1.address,
                    name = "ILCE-7CM2",
                    isSony = true,
                    isBonded = true,
                    connectGatt = { cb ->
                        connectCount++
                        val handle = if (connectCount == 1) gatt1 else gatt2
                        handle.callback = cb
                        handle
                    },
                    createBond = { true },
                ),
            )
            platform.drain()
            conn.connect(gatt1.address)
            platform.drain()
            assertEquals(1, connectCount)

            gatt1.callback!!.onConnectionStateChange(gatt1, 133, BluetoothProfile.STATE_DISCONNECTED)
            platform.drain()
            assertTrue("First transient failure must schedule retry without failing", listener.failures.isEmpty())
            assertTrue(gatt1.disconnected && gatt1.closed)
            assertEquals(1, connectCount)

            platform.advanceBy(399L)
            assertEquals(1, connectCount)
            platform.advanceBy(1L)
            assertEquals(2, connectCount)

            gatt2.callback!!.onConnectionStateChange(gatt2, BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_CONNECTED)
            platform.drain()
            assertEquals(SonyCameraConnection.Stage.WIFI_STARTING, listener.stages.last())
            assertTrue(listener.failures.isEmpty())
            conn.close()
        }

        // Part B: 3 consecutive status=62 (0x3e) failures fail with Failure.BLUETOOTH after attempt 3
        run {
            val platform = FakePlatform()
            val listener = RecordingListener()
            val gattList = List(3) { FakeGatt() }
            var connectCount = 0
            val (conn, _) = createConnection(platform, listener)

            conn.scan()
            platform.drain()
            platform.onScanEntry?.invoke(
                SonyCameraConnection.BleScanEntry(
                    id = gattList[0].address,
                    name = "ILCE-7CM2",
                    isSony = true,
                    isBonded = true,
                    connectGatt = { cb ->
                        val handle = gattList[connectCount++]
                        handle.callback = cb
                        handle
                    },
                    createBond = { true },
                ),
            )
            platform.drain()
            conn.connect(gattList[0].address)
            platform.drain()
            assertEquals(1, connectCount)

            // Attempt 1 (t = 0)
            gattList[0].callback!!.onConnectionStateChange(gattList[0], 62, BluetoothProfile.STATE_DISCONNECTED)
            platform.drain()
            assertTrue(listener.failures.isEmpty())

            // Attempt 2 (+400ms)
            platform.advanceBy(400L)
            assertEquals(2, connectCount)
            gattList[1].callback!!.onConnectionStateChange(gattList[1], 62, BluetoothProfile.STATE_DISCONNECTED)
            platform.drain()
            assertTrue(listener.failures.isEmpty())

            // Attempt 3 (+800ms) -> exhausted MAX_GATT_CONNECT_ATTEMPTS, fails immediately
            platform.advanceBy(800L)
            assertEquals(3, connectCount)
            gattList[2].callback!!.onConnectionStateChange(gattList[2], 62, BluetoothProfile.STATE_DISCONNECTED)
            platform.drain()
            assertEquals(listOf(SonyCameraConnection.Failure.BLUETOOTH), listener.failures)
        }
    }

    @Test
    fun manualWifiTimesOutWithFailureWifiWhenNoNetworkResolves() {
        val platform = FakePlatform()
        val listener = RecordingListener()
        val (conn, _) = createConnection(platform, listener, manualWifiTimeoutMs = 15_000L)

        conn.useLegacyWifi()
        platform.drain()
        assertEquals(SonyCameraConnection.Stage.MANUAL_WIFI, listener.stages.last())
        assertTrue(listener.failures.isEmpty())
        assertFalse(platform.manualWifiHandleClosed)

        platform.advanceBy(14_999L)
        assertTrue(listener.failures.isEmpty())
        assertFalse(platform.manualWifiHandleClosed)

        platform.advanceBy(1L)
        assertEquals(listOf(SonyCameraConnection.Failure.WIFI), listener.failures)
        assertTrue(platform.manualWifiHandleClosed)
    }

    @Test
    fun selectsWpa3SecurityAndRetriesSaeOnUnavailable() {
        assertFalse(advertisesWpa3Sae("[WPA2-PSK-CCMP][ESS]"))
        assertFalse(advertisesWpa3Sae("[RSAE-PSK][ESS]"))
        assertTrue(advertisesWpa3Sae("[RSN-SAE-CCMP][ESS]"))
        assertTrue(advertisesWpa3Sae("[WPA2-PSK+SAE-CCMP][ESS]"))
        assertEquals(SonyCameraConnection.WifiSecurity.WPA2, selectWifiSecurity("[WPA2-PSK-CCMP][ESS]"))
        assertEquals(SonyCameraConnection.WifiSecurity.WPA3, selectWifiSecurity("[RSN-SAE-CCMP][ESS]"))
        assertEquals(SonyCameraConnection.WifiSecurity.WPA2, selectWifiSecurity("[WPA2-PSK+SAE-CCMP][ESS]"))

        // 1. Pure WPA3-SAE chooses WPA3 immediately.
        run {
            val platform = FakePlatform()
            val listener = RecordingListener()
            val (conn, _) = createConnection(platform, listener)
            val gatt = FakeGatt()
            advanceToWifiStarting(conn, platform, gatt)
            platform.scanResultsList = listOf(
                SonyCameraConnection.WifiApResult(
                    ssid = "DIRECT-x123:ILCE-7CM2",
                    bssid = "12:34:56:78:9a:bc",
                    timestampMicros = platform.elapsedMicros() + 3_000_000L,
                    capabilities = "[RSN-SAE-CCMP][ESS]",
                ),
            )
            deliverCredentials(platform, gatt)
            assertEquals(listOf(SonyCameraConnection.WifiSecurity.WPA3), platform.requestedSecurities)
            assertTrue(listener.failures.isEmpty())
        }

        // 2. WPA2/WPA3 transition tries WPA2 first, then retries once with WPA3 onUnavailable().
        run {
            val platform = FakePlatform()
            val listener = RecordingListener()
            val (conn, _) = createConnection(platform, listener)
            val gatt = FakeGatt()
            advanceToWifiStarting(conn, platform, gatt)
            platform.scanResultsList = listOf(
                SonyCameraConnection.WifiApResult(
                    ssid = "DIRECT-x123:ILCE-7CM2",
                    bssid = "12:34:56:78:9a:bc",
                    timestampMicros = platform.elapsedMicros() + 3_000_000L,
                    capabilities = "[WPA2-PSK+SAE-CCMP][ESS]",
                ),
            )
            deliverCredentials(platform, gatt)
            assertEquals(listOf(SonyCameraConnection.WifiSecurity.WPA2), platform.requestedSecurities)
            platform.activeWifiCallbacks!!.onUnavailable()
            platform.drain()
            assertEquals(
                listOf(SonyCameraConnection.WifiSecurity.WPA2, SonyCameraConnection.WifiSecurity.WPA3),
                platform.requestedSecurities,
            )
            assertTrue(listener.failures.isEmpty())

            // Second onUnavailable fails with Failure.WIFI (no infinite retry).
            platform.activeWifiCallbacks!!.onUnavailable()
            platform.drain()
            assertEquals(listOf(SonyCameraConnection.Failure.WIFI), listener.failures)
        }

        // 3. WPA2-only fails immediately onUnavailable without WPA3 retry.
        run {
            val platform = FakePlatform()
            val listener = RecordingListener()
            val (conn, _) = createConnection(platform, listener)
            val gatt = FakeGatt()
            advanceToWifiStarting(conn, platform, gatt)
            platform.scanResultsList = listOf(
                SonyCameraConnection.WifiApResult(
                    ssid = "DIRECT-x123:ILCE-7CM2",
                    bssid = "12:34:56:78:9a:bc",
                    timestampMicros = platform.elapsedMicros() + 3_000_000L,
                    capabilities = "[WPA2-PSK-CCMP][ESS]",
                ),
            )
            deliverCredentials(platform, gatt)
            platform.activeWifiCallbacks!!.onUnavailable()
            platform.drain()
            assertEquals(listOf(SonyCameraConnection.WifiSecurity.WPA2), platform.requestedSecurities)
            assertEquals(listOf(SonyCameraConnection.Failure.WIFI), listener.failures)
        }

        // 4. SSID-only fallback still picks up cached SAE capabilities while keeping bssid = null.
        run {
            val platform = FakePlatform()
            val listener = RecordingListener()
            val (conn, _) = createConnection(platform, listener, wifiScanFallbackMs = 4_000L)
            val gatt = FakeGatt()
            advanceToWifiStarting(conn, platform, gatt)
            platform.scanResultsList = listOf(
                SonyCameraConnection.WifiApResult(
                    ssid = "DIRECT-x123:ILCE-7CM2",
                    bssid = "12:34:56:78:9a:bc",
                    timestampMicros = 0L, // stale BSSID must not be used
                    capabilities = "[RSN-SAE-CCMP][ESS]",
                ),
            )
            deliverCredentials(platform, gatt)
            platform.advanceBy(4_000L)
            assertNull(platform.requestedBssid)
            assertEquals(SonyCameraConnection.WifiSecurity.WPA3, platform.requestedSecurity)
        }

        // 5. Unknown/blank scan capabilities fall back once to WPA3 onUnavailable(), then fail on second onUnavailable().
        run {
            val platform = FakePlatform()
            val listener = RecordingListener()
            val (conn, _) = createConnection(platform, listener, wifiScanFallbackMs = 4_000L)
            val gatt = FakeGatt()
            advanceToWifiStarting(conn, platform, gatt)
            platform.scanResultsList = emptyList()
            deliverCredentials(platform, gatt)
            platform.advanceBy(4_000L)
            assertEquals(listOf(SonyCameraConnection.WifiSecurity.WPA2), platform.requestedSecurities)
            platform.activeWifiCallbacks!!.onUnavailable()
            platform.drain()
            assertEquals(
                listOf(SonyCameraConnection.WifiSecurity.WPA2, SonyCameraConnection.WifiSecurity.WPA3),
                platform.requestedSecurities,
            )
            assertTrue(listener.failures.isEmpty())

            platform.activeWifiCallbacks!!.onUnavailable()
            platform.drain()
            assertEquals(listOf(SonyCameraConnection.Failure.WIFI), listener.failures)
        }
    }

    @Test
    fun resolveCameraIpv4GatewayAppliesAllFallbacksSafely() {
        fun ipv4(s: String): Inet4Address = InetAddress.getByName(s) as Inet4Address
        val phoneIp = Ipv4LinkCandidate(ipv4("192.168.122.15"), 24)

        // 1. Default route wins first.
        assertEquals(
            ipv4("192.168.122.1"),
            resolveCameraIpv4Gateway(
                routes = listOf(Ipv4RouteCandidate(isDefaultRoute = true, hasGateway = true, gateway = ipv4("192.168.122.1"), destinationPrefixLength = 0)),
                dhcpServerAddress = ipv4("192.168.122.2"),
                linkAddresses = listOf(phoneIp),
                dnsServers = listOf(ipv4("192.168.122.3")),
            ),
        )

        // 2. No default route -> DHCP server wins.
        assertEquals(
            ipv4("192.168.122.1"),
            resolveCameraIpv4Gateway(
                routes = listOf(Ipv4RouteCandidate(isDefaultRoute = false, hasGateway = true, gateway = ipv4("192.168.122.9"), destinationPrefixLength = 0)),
                dhcpServerAddress = ipv4("192.168.122.1"),
                linkAddresses = listOf(phoneIp),
                dnsServers = listOf(ipv4("192.168.122.3")),
            ),
        )

        // 3. No default route or DHCP -> non-default private route gateway wins.
        assertEquals(
            ipv4("192.168.122.1"),
            resolveCameraIpv4Gateway(
                routes = listOf(
                    Ipv4RouteCandidate(isDefaultRoute = false, hasGateway = false, gateway = ipv4("0.0.0.0"), destinationPrefixLength = 24),
                    Ipv4RouteCandidate(isDefaultRoute = false, hasGateway = true, gateway = ipv4("192.168.122.1"), destinationPrefixLength = 0),
                ),
                dhcpServerAddress = null,
                linkAddresses = listOf(phoneIp),
                dnsServers = emptyList(),
            ),
        )

        // 4. Same-subnet private DNS wins over public DNS or own IP.
        assertEquals(
            ipv4("192.168.122.1"),
            resolveCameraIpv4Gateway(
                routes = emptyList(),
                dhcpServerAddress = null,
                linkAddresses = listOf(phoneIp),
                dnsServers = listOf(ipv4("8.8.8.8"), phoneIp.address, ipv4("192.168.122.1")),
            ),
        )

        // 5. No route, no DHCP, only public DNS -> infers .1 of RFC1918 /24 subnet.
        assertEquals(
            ipv4("192.168.122.1"),
            resolveCameraIpv4Gateway(
                routes = emptyList(),
                dhcpServerAddress = null,
                linkAddresses = listOf(phoneIp),
                dnsServers = listOf(ipv4("8.8.8.8")),
            ),
        )

        // Does not infer .1 when phone itself holds .1.
        assertNull(
            resolveCameraIpv4Gateway(
                routes = emptyList(),
                dhcpServerAddress = null,
                linkAddresses = listOf(Ipv4LinkCandidate(ipv4("192.168.122.1"), 24)),
                dnsServers = emptyList(),
            ),
        )
    }

    @Test
    fun manualWifiSelectorPrefersDualWlanCameraApAndHandlesRedactedBssid() {
        fun ipv4(s: String): Inet4Address = InetAddress.getByName(s) as Inet4Address

        // Scenario A: Home Wi-Fi (validated) arrives first; Dual-WLAN camera AP arrives at +150ms -> camera AP wins.
        val dualSelector = ManualWifiSelector(dualWlanSettleDelayMs = 400L, bssidGraceDelayMs = 2_000L)
        dualSelector.update(
            ManualWifiObservation(
                networkKey = "net-home",
                ssid = "Home5G",
                bssid = "00:11:22:33:44:55",
                gateway = ipv4("192.168.1.1"),
                validated = true,
            ),
            nowMs = 0L,
        )
        assertNull(dualSelector.pollSelected(nowMs = 0L))
        assertEquals(400L, dualSelector.nextEvaluationDelayMs(nowMs = 0L))

        dualSelector.update(
            ManualWifiObservation(
                networkKey = "net-cam",
                ssid = "\"DIRECT-a7m5:ILCE-7M5\"",
                bssid = "aa:bb:cc:dd:ee:ff",
                gateway = ipv4("192.168.122.1"),
                validated = false,
            ),
            nowMs = 150L,
        )
        assertEquals(0L, dualSelector.nextEvaluationDelayMs(nowMs = 150L))
        val picked = dualSelector.pollSelected(nowMs = 150L)!!
        assertEquals("net-cam", picked.first.networkKey)
        assertEquals("sony-wifi:aa:bb:cc:dd:ee:ff", picked.second)

        // Scenario B: BSSID redacted to 02:00:00:00:00:00 -> waits grace then falls back to sony-wifi-ssid:<ssid>.
        val redactedSelector = ManualWifiSelector(dualWlanSettleDelayMs = 400L, bssidGraceDelayMs = 2_000L)
        redactedSelector.update(
            ManualWifiObservation(
                networkKey = "net-cam",
                ssid = "\"DIRECT-a7m5:ILCE-7M5\"",
                bssid = "02:00:00:00:00:00",
                gateway = ipv4("192.168.122.1"),
                validated = false,
            ),
            nowMs = 1_000L,
        )
        assertNull(redactedSelector.pollSelected(nowMs = 2_500L))
        assertEquals(500L, redactedSelector.nextEvaluationDelayMs(nowMs = 2_500L))
        val fallbackPicked = redactedSelector.pollSelected(nowMs = 3_000L)!!
        assertEquals("sony-wifi-ssid:DIRECT-a7m5:ILCE-7M5", fallbackPicked.second)

        // Scenario C: Redacted both SSID & BSSID -> falls back to sony-wifi-route:<gateway>.
        val routeOnlySelector = ManualWifiSelector(dualWlanSettleDelayMs = 400L, bssidGraceDelayMs = 2_000L)
        routeOnlySelector.update(
            ManualWifiObservation(
                networkKey = "net-anon",
                ssid = "<unknown ssid>",
                bssid = "02:00:00:00:00:00",
                gateway = ipv4("192.168.122.1"),
                validated = false,
            ),
            nowMs = 0L,
        )
        assertEquals("sony-wifi-route:192.168.122.1", routeOnlySelector.pollSelected(nowMs = 2_000L)!!.second)

        // Scenario D: Real BSSID arrives before grace ends -> upgrades immediately.
        val upgradeSelector = ManualWifiSelector(dualWlanSettleDelayMs = 400L, bssidGraceDelayMs = 2_000L)
        upgradeSelector.update(
            ManualWifiObservation(
                networkKey = "net-cam",
                ssid = "DIRECT-a7m5:ILCE-7M5",
                bssid = "02:00:00:00:00:00",
                gateway = ipv4("192.168.122.1"),
                validated = false,
            ),
            nowMs = 0L,
        )
        assertNull(upgradeSelector.pollSelected(nowMs = 100L))
        upgradeSelector.update(
            ManualWifiObservation(
                networkKey = "net-cam",
                ssid = "DIRECT-a7m5:ILCE-7M5",
                bssid = "aa:bb:cc:dd:ee:ff",
                gateway = ipv4("192.168.122.1"),
                validated = false,
            ),
            nowMs = 250L,
        )
        assertEquals("sony-wifi:aa:bb:cc:dd:ee:ff", upgradeSelector.pollSelected(nowMs = 250L)!!.second)
    }

    @Test
    fun unbondedCameraWithoutRequiredCharacteristicsFallsBackToManualWifiWithoutBonding() {
        // Case A: ZV-E10 advertises BLE, is unbonded, negotiates small MTU (23), and lacks 8000cc00/8000ee00.
        // Must probe GATT first, NEVER call createBond(), close GATT, and switch directly to MANUAL_WIFI.
        run {
            val platform = FakePlatform()
            val listener = RecordingListener()
            val gatt = FakeGatt(
                address = "34:90:EA:E6:D5:3A",
                requiredCharacteristics = false,
                mtuResult = 23,
            )
            var createBondCalls = 0
            var gattConnectCalls = 0
            val (conn, _) = createConnection(platform, listener)

            conn.scan()
            platform.drain()
            platform.onScanEntry?.invoke(
                SonyCameraConnection.BleScanEntry(
                    id = gatt.address,
                    name = "ZV-E10",
                    isSony = true,
                    isBonded = false,
                    connectGatt = { cb ->
                        gattConnectCalls++
                        gatt.callback = cb
                        gatt
                    },
                    createBond = {
                        createBondCalls++
                        true
                    },
                ),
            )
            platform.drain()
            conn.connect(gatt.address)
            platform.drain()

            assertEquals("Must open GATT before bonding to probe services", 1, gattConnectCalls)
            assertEquals("Must not call createBond() before service discovery", 0, createBondCalls)
            assertEquals(SonyCameraConnection.Stage.BLUETOOTH, listener.stages.last())

            gatt.callback!!.onConnectionStateChange(gatt, BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_CONNECTED)
            platform.drain()

            assertEquals(0, createBondCalls)
            assertEquals(1, gatt.discoverServicesCalls)
            assertTrue("GATT must be closed on MANUAL_WIFI fallback", gatt.disconnected && gatt.closed)
            assertEquals(SonyCameraConnection.Stage.MANUAL_WIFI, listener.stages.last())
            assertEquals(1, listener.manualWifiFallbackCount)
            assertTrue(listener.failures.isEmpty())
            conn.close()
        }

        // Case B: requestMtu() returns false -> still discovers services and falls back cleanly to MANUAL_WIFI.
        run {
            val platform = FakePlatform()
            val listener = RecordingListener()
            val gatt = FakeGatt(
                address = "34:90:EA:E6:D5:3A",
                requiredCharacteristics = false,
                requestMtuReturn = false,
            )
            var createBondCalls = 0
            val (conn, _) = createConnection(platform, listener)

            conn.scan()
            platform.drain()
            platform.onScanEntry?.invoke(
                SonyCameraConnection.BleScanEntry(
                    id = gatt.address,
                    name = "ZV-E10",
                    isSony = true,
                    isBonded = false,
                    connectGatt = { cb -> gatt.callback = cb; gatt },
                    createBond = { createBondCalls++; true },
                ),
            )
            platform.drain()
            conn.connect(gatt.address)
            platform.drain()
            gatt.callback!!.onConnectionStateChange(gatt, BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_CONNECTED)
            platform.drain()

            assertEquals(0, createBondCalls)
            assertEquals(1, gatt.discoverServicesCalls)
            assertEquals(SonyCameraConnection.Stage.MANUAL_WIFI, listener.stages.last())
            assertEquals(1, listener.manualWifiFallbackCount)
            assertTrue(listener.failures.isEmpty())
            conn.close()
        }
    }

    @Test
    fun unbondedCameraWithRequiredCharacteristicsDiscoversServicesThenBondsAndProceeds() {
        // Case A: GATT stays up across BOND_BONDED -> proceeds directly to writePairingInit + writeWifiOn.
        run {
            val platform = FakePlatform()
            val listener = RecordingListener()
            val gatt = FakeGatt(address = "B0:65:3A:51:C5:E8", requiredCharacteristics = true)
            var createBondCalls = 0
            var gattConnectCalls = 0
            val (conn, _) = createConnection(platform, listener)

            conn.scan()
            platform.drain()
            platform.onScanEntry?.invoke(
                SonyCameraConnection.BleScanEntry(
                    id = gatt.address,
                    name = "ILCE-7CM2",
                    isSony = true,
                    isBonded = false,
                    connectGatt = { cb -> gattConnectCalls++; gatt.callback = cb; gatt },
                    createBond = { createBondCalls++; true },
                ),
            )
            platform.drain()
            conn.connect(gatt.address)
            platform.drain()
            assertEquals(1, gattConnectCalls)
            assertEquals(0, createBondCalls)

            gatt.callback!!.onConnectionStateChange(gatt, BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_CONNECTED)
            platform.drain()

            assertEquals("Must call createBond() only after confirming required GATT services", 1, createBondCalls)
            assertEquals(SonyCameraConnection.Stage.PAIRING, listener.stages.last())
            assertFalse("Must wait for BOND_BONDED before writing ee01", gatt.writePairingInitCalled)

            platform.onBondChangedCallback!!.invoke(gatt.address, BluetoothDevice.BOND_BONDING)
            platform.onBondChangedCallback!!.invoke(gatt.address, BluetoothDevice.BOND_BONDED)
            platform.drain()

            assertEquals(1, gattConnectCalls)
            assertTrue(gatt.writePairingInitCalled)
            assertTrue(gatt.writeWifiOnCalled)
            assertEquals(SonyCameraConnection.Stage.WIFI_STARTING, listener.stages.last())
            assertTrue(listener.failures.isEmpty())
            conn.close()
        }

        // Case B: GATT drops during PAIRING -> does not fail; reopens GATT on BOND_BONDED without re-bonding.
        run {
            val platform = FakePlatform()
            val listener = RecordingListener()
            val gatt1 = FakeGatt(address = "B0:65:3A:51:C5:E8", requiredCharacteristics = true)
            val gatt2 = FakeGatt(address = "B0:65:3A:51:C5:E8", requiredCharacteristics = true)
            var createBondCalls = 0
            var gattConnectCalls = 0
            val (conn, _) = createConnection(platform, listener)

            conn.scan()
            platform.drain()
            platform.onScanEntry?.invoke(
                SonyCameraConnection.BleScanEntry(
                    id = gatt1.address,
                    name = "ILCE-7CM2",
                    isSony = true,
                    isBonded = false,
                    connectGatt = { cb ->
                        gattConnectCalls++
                        val handle = if (gattConnectCalls == 1) gatt1 else gatt2
                        handle.callback = cb
                        handle
                    },
                    createBond = { createBondCalls++; true },
                ),
            )
            platform.drain()
            conn.connect(gatt1.address)
            platform.drain()
            gatt1.callback!!.onConnectionStateChange(gatt1, BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_CONNECTED)
            platform.drain()
            assertEquals(SonyCameraConnection.Stage.PAIRING, listener.stages.last())
            assertEquals(1, createBondCalls)

            // Disconnect during PAIRING must close stale GATT without failing the bond attempt.
            gatt1.callback!!.onConnectionStateChange(gatt1, 19, BluetoothProfile.STATE_DISCONNECTED)
            platform.drain()
            assertTrue(listener.failures.isEmpty())
            assertTrue(gatt1.closed)

            platform.onBondChangedCallback!!.invoke(gatt1.address, BluetoothDevice.BOND_BONDED)
            platform.drain()
            assertEquals(2, gattConnectCalls)
            assertEquals(1, createBondCalls)

            gatt2.callback!!.onConnectionStateChange(gatt2, BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_CONNECTED)
            platform.drain()
            assertEquals(1, createBondCalls)
            assertTrue(gatt2.writePairingInitCalled)
            assertTrue(gatt2.writeWifiOnCalled)
            assertEquals(SonyCameraConnection.Stage.WIFI_STARTING, listener.stages.last())
            assertTrue(listener.failures.isEmpty())
            conn.close()
        }

        // Case C: Bonding rejected (BOND_NONE) -> fails with Failure.PAIRING and dedicated pairing failure string.
        run {
            val platform = FakePlatform()
            val listener = RecordingListener()
            val gatt = FakeGatt(address = "B0:65:3A:51:C5:E8", requiredCharacteristics = true)
            val (conn, _) = createConnection(platform, listener)

            conn.scan()
            platform.drain()
            platform.onScanEntry?.invoke(
                SonyCameraConnection.BleScanEntry(
                    id = gatt.address,
                    name = "ILCE-7CM2",
                    isSony = true,
                    isBonded = false,
                    connectGatt = { cb -> gatt.callback = cb; gatt },
                    createBond = { true },
                ),
            )
            platform.drain()
            conn.connect(gatt.address)
            platform.drain()
            gatt.callback!!.onConnectionStateChange(gatt, BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_CONNECTED)
            platform.drain()
            assertEquals(SonyCameraConnection.Stage.PAIRING, listener.stages.last())

            platform.onBondChangedCallback!!.invoke(gatt.address, BluetoothDevice.BOND_NONE)
            platform.drain()
            assertEquals(listOf(SonyCameraConnection.Failure.PAIRING), listener.failures)
            assertEquals(R.string.camera_pairing_failed, cameraFailureMessage(SonyCameraConnection.Failure.PAIRING))
            assertNotEquals(R.string.camera_connection_failed, cameraFailureMessage(SonyCameraConnection.Failure.PAIRING))
        }

        // Case D: Bonded camera WITH required services but small MTU (<67) still fails with Failure.BLUETOOTH.
        run {
            val platform = FakePlatform()
            val listener = RecordingListener()
            val gatt = FakeGatt(address = "B0:65:3A:51:C5:E8", requiredCharacteristics = true, mtuResult = 23)
            val (conn, _) = createConnection(platform, listener)

            conn.scan()
            platform.drain()
            platform.onScanEntry?.invoke(
                SonyCameraConnection.BleScanEntry(
                    id = gatt.address,
                    name = "ILCE-7CM2",
                    isSony = true,
                    isBonded = true,
                    connectGatt = { cb -> gatt.callback = cb; gatt },
                    createBond = { true },
                ),
            )
            platform.drain()
            conn.connect(gatt.address)
            platform.drain()
            gatt.callback!!.onConnectionStateChange(gatt, BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_CONNECTED)
            platform.drain()

            assertEquals(listOf(SonyCameraConnection.Failure.BLUETOOTH), listener.failures)
            assertFalse(gatt.writePairingInitCalled)
        }

        // Case E: Reused pre-bond GATT fails ee01 with GATT_INSUFFICIENT_AUTHENTICATION (5) -> retries once on fresh post-bond GATT.
        run {
            val platform = FakePlatform()
            val listener = RecordingListener()
            val gatt1 = FakeGatt(address = "B0:65:3A:51:C5:E8", requiredCharacteristics = true, pairingInitStatus = 5)
            val gatt2 = FakeGatt(address = "B0:65:3A:51:C5:E8", requiredCharacteristics = true, pairingInitStatus = BluetoothGatt.GATT_SUCCESS)
            var createBondCalls = 0
            var gattConnectCalls = 0
            val (conn, _) = createConnection(platform, listener)

            conn.scan()
            platform.drain()
            platform.onScanEntry?.invoke(
                SonyCameraConnection.BleScanEntry(
                    id = gatt1.address,
                    name = "ILCE-7CM2",
                    isSony = true,
                    isBonded = false,
                    connectGatt = { cb ->
                        gattConnectCalls++
                        val handle = if (gattConnectCalls == 1) gatt1 else gatt2
                        handle.callback = cb
                        handle
                    },
                    createBond = { createBondCalls++; true },
                ),
            )
            platform.drain()
            conn.connect(gatt1.address)
            platform.drain()
            gatt1.callback!!.onConnectionStateChange(gatt1, BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_CONNECTED)
            platform.drain()
            assertEquals(SonyCameraConnection.Stage.PAIRING, listener.stages.last())

            platform.onBondChangedCallback!!.invoke(gatt1.address, BluetoothDevice.BOND_BONDED)
            platform.drain()
            assertTrue(gatt1.writePairingInitCalled)
            assertTrue(gatt1.closed)
            assertEquals("Must reopen GATT once when pre-bond handle rejects ee01", 2, gattConnectCalls)
            assertTrue(listener.failures.isEmpty())

            gatt2.callback!!.onConnectionStateChange(gatt2, BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_CONNECTED)
            platform.drain()
            assertEquals(1, createBondCalls)
            assertTrue(gatt2.writePairingInitCalled)
            assertTrue(gatt2.writeWifiOnCalled)
            assertEquals(SonyCameraConnection.Stage.WIFI_STARTING, listener.stages.last())
            assertTrue(listener.failures.isEmpty())
            conn.close()
        }
    }

    @Test
    fun cameraConnectionRecordsRedactedDiagnosticsBreadcrumbsAndErrors() {
        val diagDir = Files.createTempDirectory("sony-conn-diag-test").toFile()
        val store = DiagnosticSessionStore(
            directory = diagDir,
            environment = DiagnosticEnvironmentInfo(
                appVersion = "0.13.0",
                build = "25",
                osVersion = "15",
                deviceModel = "TEST_DEVICE",
            ),
        )
        store.setRecordingEnabled(true)
        CameraDiagnostics.storeOverride = store
        try {
            // 1. ZV-E10 manual Wi-Fi fallback records breadcrumbs without leaking MAC or raw custom ad name.
            run {
                val platform = FakePlatform()
                val listener = RecordingListener()
                val gatt = FakeGatt(
                    address = "34:90:EA:E6:D5:3A",
                    requiredCharacteristics = false,
                    mtuResult = 23,
                    serviceSummary = "none",
                )
                val (conn, _) = createConnection(platform, listener)
                conn.scan()
                platform.drain()
                platform.onScanEntry?.invoke(
                    SonyCameraConnection.BleScanEntry(
                        id = gatt.address,
                        name = "ZV-E10.secret-owner",
                        isSony = true,
                        isBonded = false,
                        connectGatt = { cb -> gatt.callback = cb; gatt },
                        createBond = { true },
                    ),
                )
                platform.drain()
                conn.connect(gatt.address)
                platform.drain()
                gatt.callback!!.onConnectionStateChange(gatt, BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_CONNECTED)
                platform.drain()
                conn.close()
            }

            // 2. Pairing rejection records recent-error entry under operation "camera".
            run {
                val platform = FakePlatform()
                val listener = RecordingListener()
                val gatt = FakeGatt(address = "B0:65:3A:51:C5:E8", requiredCharacteristics = true)
                val (conn, _) = createConnection(platform, listener)
                conn.scan()
                platform.drain()
                platform.onScanEntry?.invoke(
                    SonyCameraConnection.BleScanEntry(
                        id = gatt.address,
                        name = "ILCE-7CM2.my-private-tag",
                        isSony = true,
                        isBonded = false,
                        connectGatt = { cb -> gatt.callback = cb; gatt },
                        createBond = { true },
                    ),
                )
                platform.drain()
                conn.connect(gatt.address)
                platform.drain()
                gatt.callback!!.onConnectionStateChange(gatt, BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_CONNECTED)
                platform.drain()
                platform.onBondChangedCallback!!.invoke(gatt.address, BluetoothDevice.BOND_NONE)
                platform.drain()
            }

            // 3. Wi-Fi credential exchange never leaks SSID, password, or IPv4 addresses.
            run {
                val platform = FakePlatform()
                val listener = RecordingListener()
                val gatt = FakeGatt(address = "AA:BB:CC:DD:EE:FF", requiredCharacteristics = true)
                val (conn, _) = createConnection(platform, listener)
                advanceToWifiStarting(conn, platform, gatt)
                platform.scanResultsList = listOf(
                    SonyCameraConnection.WifiApResult(
                        "DIRECT-x123:ILCE-7CM2",
                        "02:11:22:33:44:55",
                        platform.elapsedMicros() + 3_000_000L,
                    ),
                )
                deliverCredentials(platform, gatt)
                CameraDiagnostics.error(
                    stage = "openImportSession",
                    error = java.io.IOException("connect failed to 192.168.122.1:15740"),
                )
                conn.close()
            }

            val pkg = store.buildReportPackage(stopActiveRecording = true)
            val breadcrumbEntries = pkg.breadcrumbsJSONL
                .lineSequence()
                .filter { it.isNotBlank() }
                .map { org.json.JSONObject(it) }
                .toList()
            val cameraStages = breadcrumbEntries
                .filter { it.optString("category") == "camera" }
                .map { it.optString("stage") }
                .toSet()
            assertTrue("Expected bleConnectStart breadcrumb", "bleConnectStart" in cameraStages)
            assertTrue("Expected gattServicesDiscovered breadcrumb", "gattServicesDiscovered" in cameraStages)
            assertTrue("Expected bleManualWifiFallback breadcrumb", "bleManualWifiFallback" in cameraStages)
            assertTrue("Expected bleBondStart breadcrumb", "bleBondStart" in cameraStages)
            assertTrue("Expected bleBondState breadcrumb", "bleBondState" in cameraStages)
            assertTrue("Expected wifiRequest breadcrumb", "wifiRequest" in cameraStages)

            val errorsJson = org.json.JSONObject(pkg.recentErrorsJSON)
            val events = errorsJson.getJSONArray("events")
            val errorItems = (0 until events.length()).map { events.getJSONObject(it) }
            assertTrue(
                "Expected PAIRING failure in recent-errors.json",
                errorItems.any {
                    it.optString("operation") == "camera" &&
                        it.optString("stage") == "bleWifiConnection" &&
                        it.optString("message").contains("PAIRING")
                },
            )
            assertTrue(
                "Expected openImportSession failure in recent-errors.json",
                errorItems.any {
                    it.optString("operation") == "camera" &&
                        it.optString("stage") == "openImportSession"
                },
            )

            val combined = pkg.breadcrumbsJSONL + "\n" + pkg.recentErrorsJSON
            assertFalse("MAC address must not leak to diagnostics", combined.contains("34:90:EA:E6:D5:3A", ignoreCase = true))
            assertFalse("MAC address must not leak to diagnostics", combined.contains("B0:65:3A:51:C5:E8", ignoreCase = true))
            assertFalse("Custom camera name must not leak", combined.contains("secret-owner"))
            assertFalse("Custom camera name must not leak", combined.contains("my-private-tag"))
            assertFalse("Camera SSID must not leak", combined.contains("DIRECT-x123"))
            assertFalse("Camera Wi-Fi password must not leak", combined.contains("secretpass"))
            assertFalse("Camera IP must be redacted", combined.contains("192.168.122.1"))
        } finally {
            CameraDiagnostics.storeOverride = null
            diagDir.deleteRecursively()
        }
    }

    @Test
    fun bondedCameraWithoutWifiOnFallsBackToManualWifiWithoutWritingEe01() {
        val platform = FakePlatform()
        val listener = RecordingListener()
        val gatt = FakeGatt(
            address = "34:90:EA:E6:D5:3A",
            requiredCharacteristics = false,
            wifiOnCharacteristic = false,
            mtuResult = 517,
            serviceSummary = "8000cc00:[cc01(N),cc02(W),cc05(RN),cc06(R),cc07(R)],8000ee00:[ee01(W)]",
        )
        var createBondCalls = 0
        val (conn, _) = createConnection(platform, listener)

        conn.scan()
        platform.drain()
        platform.onScanEntry?.invoke(
            SonyCameraConnection.BleScanEntry(
                id = gatt.address,
                name = "ZV-E10",
                isSony = true,
                isBonded = true,
                connectGatt = { cb -> gatt.callback = cb; gatt },
                createBond = { createBondCalls++; true },
            ),
        )
        platform.drain()
        conn.connect(gatt.address)
        platform.drain()
        gatt.callback!!.onConnectionStateChange(gatt, BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_CONNECTED)
        platform.drain()

        assertEquals(0, createBondCalls)
        assertFalse("Must not write ee01 when cc08 is absent", gatt.writePairingInitCalled)
        assertFalse("Must not read cc06 when cc08 is absent", gatt.readSsidCalled)
        assertEquals(SonyCameraConnection.Stage.MANUAL_WIFI, listener.stages.last())
        assertEquals(1, listener.manualWifiFallbackCount)
        assertTrue(listener.failures.isEmpty())
        conn.close()
    }

    @Test
    fun sonyCameraBleNameMatcherIdentifiesSonyModelsAndRejectsUnrelatedDevices() {
        assertTrue(isSonyCameraBleName("ZV-E10"))
        assertTrue(isSonyCameraBleName("ZV-1"))
        assertTrue(isSonyCameraBleName("ILCE-7CM2.xp"))
        assertTrue(isSonyCameraBleName("ILCE-7M4"))
        assertTrue(isSonyCameraBleName("ILME-FX3"))
        assertTrue(isSonyCameraBleName("DSC-RX100M7"))
        assertTrue(isSonyCameraBleName("zv-e10"))
        assertFalse(isSonyCameraBleName("HUAWEI FreeBuds SE 4 ANC"))
        assertFalse(isSonyCameraBleName("ONIX XP1"))
        assertFalse(isSonyCameraBleName(""))
        assertFalse(isSonyCameraBleName("   "))
        assertFalse(isSonyCameraBleName(null))
    }
}
