package com.rawlab.android.camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build
import androidx.test.core.app.ActivityScenario
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.After
import org.junit.Rule
import org.junit.Test
import com.rawlab.android.MainActivity
import com.rawlab.android.testing.ForegroundTestRule
import java.net.InetAddress
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@SdkSuppress(minSdkVersion = 29)
class SonyManualWifiConnectionTest {
    @get:Rule val foreground = ForegroundTestRule()
    private var activity: ActivityScenario<MainActivity>? = null

    @Before fun grantRequiredPermissions() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val permissions = buildList {
            add(Manifest.permission.ACCESS_COARSE_LOCATION)
            add(Manifest.permission.ACCESS_FINE_LOCATION)
            if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.NEARBY_WIFI_DEVICES)
        }
        permissions.forEach { instrumentation.uiAutomation.grantRuntimePermission(instrumentation.targetContext.packageName, it) }
        activity = ActivityScenario.launch(MainActivity::class.java)
    }

    @After fun closeActivity() { activity?.close() }

    @Suppress("DEPRECATION")
    @Test fun manualWifiUsesTheCallbackIdentityWithoutBluetoothPermission() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        if (Build.VERSION.SDK_INT >= 31) {
            assumeTrue("Requires a fresh install with Bluetooth permissions denied",
                context.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_DENIED &&
                    context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_DENIED)
        }
        val location = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        assumeTrue("Requires location enabled for Wi-Fi identity", location.isLocationEnabled)
        val wifi = context.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val currentInfo = wifi.connectionInfo
        val expected = SonyCameraModel.networkIdentity(currentInfo.ssid, currentInfo.bssid)
        assumeTrue("Requires an already-connected Wi-Fi network", expected != null)
        val completed = CountDownLatch(1)
        var connectedNetwork: Network? = null
        var identity: String? = null
        var failure: SonyCameraConnection.Failure? = null
        val connection = SonyCameraConnection(context, object : SonyCameraConnection.Listener {
            override fun onCandidates(items: List<CameraCandidate>) = Unit
            override fun onStage(stage: SonyCameraConnection.Stage) = Unit
            override fun onConnected(network: Network, address: InetAddress, cameraId: String) {
                connectedNetwork = network; identity = cameraId; completed.countDown()
            }
            override fun onFailure(reason: SonyCameraConnection.Failure) { failure = reason; completed.countDown() }
        })
        try {
            connection.useLegacyWifi()
            assertTrue("Manual Wi-Fi did not identify the callback network", completed.await(10, TimeUnit.SECONDS))
            assertNull(failure)
            assertEquals(expected, identity)
            assertNotNull(connectedNetwork)
            if (Build.VERSION.SDK_INT >= 31) {
                val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                val snapshot = manager.getNetworkCapabilities(connectedNetwork)?.transportInfo as? WifiInfo
                assertNull("The synchronous snapshot must not replace the callback's unredacted identity",
                    SonyCameraModel.networkIdentity(snapshot?.ssid, snapshot?.bssid))
            }
        } finally { connection.close() }
    }
}
