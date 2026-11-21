package com.rawlab.android.camera

import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.net.LinkProperties
import android.net.Network
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

        override fun registerBondReceiver(onBondChanged: (String, Int) -> Unit): SonyCameraConnection.Handle =
            object : SonyCameraConnection.Handle { override fun close() = Unit }

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
        ): SonyCameraConnection.Handle {
            requestedSsid = ssid
            requestedPassword = password
            requestedBssid = bssid
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
    ) : SonyCameraConnection.GattHandle {
        var callback: SonyCameraConnection.GattClientCallback? = null
        var disconnected = false
        var closed = false
        var writeWifiOnCalled = false
        override fun requestMtu(mtu: Int): Boolean {
            callback?.onMtuChanged(this, 158, BluetoothGatt.GATT_SUCCESS)
            return true
        }
        override fun discoverServices(): Boolean {
            callback?.onServicesDiscovered(this, BluetoothGatt.GATT_SUCCESS)
            return true
        }
        override fun hasRequiredCharacteristics(): Boolean = true
        override fun hasWifiOnCharacteristic(): Boolean = true
        override fun writePairingInit(): Boolean {
            callback?.onCharacteristicWrite(this, UUID.fromString("0000ee01-0000-1000-8000-00805f9b34fb"), BluetoothGatt.GATT_SUCCESS)
            return true
        }
        override fun writeWifiOn(): Boolean {
            writeWifiOnCalled = true
            return true
        }
        override fun readSsid(): Boolean = true
        override fun readPassword(): Boolean = true
        override fun disconnect() { disconnected = true }
        override fun close() { closed = true }
    }

    private class RecordingListener : SonyCameraConnection.Listener {
        val stages = mutableListOf<SonyCameraConnection.Stage>()
        val failures = mutableListOf<SonyCameraConnection.Failure>()
        val connected = mutableListOf<Triple<Network, InetAddress, String>>()
        override fun onCandidates(items: List<CameraCandidate>) = Unit
        override fun onStage(stage: SonyCameraConnection.Stage) { stages += stage }
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
                SonyCameraConnection.WifiApResult("DIRECT-x123:ILCE-7CM2", "02:11:22:33:44:55", platform.elapsedMicros() + 3_000_000L),
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
                SonyCameraConnection.WifiApResult("DIRECT-x123:ILCE-7CM2", "02:11:22:33:44:55", platform.elapsedMicros() + 3_000_000L),
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
                SonyCameraConnection.WifiApResult("DIRECT-x123:ILCE-7CM2", "02:11:22:33:44:55", platform.elapsedMicros() + 3_000_000L),
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
                SonyCameraConnection.WifiApResult("DIRECT-x123:ILCE-7CM2", "02:11:22:33:44:55", platform.elapsedMicros() + 3_000_000L),
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
                SonyCameraConnection.WifiApResult("DIRECT-x123:ILCE-7CM2", "02:11:22:33:44:55", platform.elapsedMicros() + 3_000_000L),
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
}
