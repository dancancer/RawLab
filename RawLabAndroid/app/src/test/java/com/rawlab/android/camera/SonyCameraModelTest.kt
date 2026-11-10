package com.rawlab.android.camera

import org.junit.Assert.*
import org.junit.Test

class SonyCameraModelTest {
    @Test fun advertisementsDoNotAcceptSimilarModelNames() {
        assertEquals(SonyCameraModel.A7CII, SonyCameraModel.fromAdvertisement("ILCE-7CM2.012345"))
        assertEquals(SonyCameraModel.ZVE10, SonyCameraModel.fromAdvertisement("ZV-E10"))
        assertEquals(SonyCameraModel.UNKNOWN, SonyCameraModel.fromAdvertisement("ZV-E10M2"))
        assertEquals(SonyCameraModel.UNKNOWN, SonyCameraModel.fromAdvertisement("Renamed camera"))
    }

    @Test fun anUnverifiedSonyAdvertisementRemainsSelectableWithoutPretendingVerification() {
        assertEquals(SonyCameraModel.UNKNOWN, SonyCameraModel.fromAdvertisement("ILCE-7M4"))
        assertEquals(SonyCameraModel.UNKNOWN, SonyCameraModel.fromIdentity("ILCE-7M4", "1.00"))
        assertEquals(SonyCameraModel.A7CII, SonyCameraModel.fromIdentity("ILCE-7CM2", "2.00"))
        assertEquals(SonyCameraModel.UNKNOWN, SonyCameraModel.fromAdvertisement("ZV-E10M2.012345"))
        assertEquals(SonyCameraModel.UNKNOWN, SonyCameraModel.fromAdvertisement("ZV-E10M2 camera"))
        assertEquals(SonyCameraModel.UNKNOWN, SonyCameraModel.fromIdentity("ZV-E10M2", "1.00"))
        assertEquals(SonyCameraModel.UNKNOWN, SonyCameraModel.fromAdvertisement(""))
        assertEquals(SonyCameraModel.UNKNOWN, SonyCameraModel.fromAdvertisement("Future Sony model"))
    }

    @Test fun unverifiedZVHotspotRemainsSelectableAndBoundToItsActualBSSID() {
        assertEquals("sony-wifi:aa:bb:cc:dd:ee:ff", SonyCameraModel.networkIdentity("DIRECT-ab12:ZV-E10M2", "AA:BB:CC:DD:EE:FF"))
        assertEquals("sony-wifi:aa:bb:cc:dd:ee:01", SonyCameraModel.networkIdentity("DIRECT-ab12:ZV-E10M2", "AA:BB:CC:DD:EE:01"))
        assertNull(SonyCameraModel.networkIdentity("DIRECT-ab12:ZV-E10M2", "02:00:00:00:00:00"))
        assertEquals("sony-wifi:aa:bb:cc:dd:ee:ff", SonyCameraModel.networkIdentity("Renamed camera Wi-Fi", "AA:BB:CC:DD:EE:FF"))
    }

    @Test fun manualNetworkIdentityIsBoundToTheActualCameraAccessPoint() {
        assertEquals("sony-wifi:aa:bb:cc:dd:ee:ff", SonyCameraModel.networkIdentity("\"DIRECT-ab12:ZV-E10\"", "AA:BB:CC:DD:EE:FF"))
        assertEquals("sony-wifi:aa:bb:cc:dd:ee:ff", SonyCameraModel.networkIdentity("Home", "aa:bb:cc:dd:ee:ff"))
        assertEquals("sony-wifi:aa:bb:cc:dd:ee:ff", SonyCameraModel.networkIdentity("DIRECT-ab12:ZV-E10M2", "aa:bb:cc:dd:ee:ff"))
        assertNull(SonyCameraModel.networkIdentity("DIRECT-ab12:ZV-E10", "02:00:00:00:00:00"))
        assertNull(SonyCameraModel.networkIdentity("DIRECT-ab12:ZV-E10", null))
    }
}
