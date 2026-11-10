package com.rawlab.android.camera

import org.junit.Assert.*
import org.junit.Test

class SonyCameraModelTest {
    @Test fun advertisementsDoNotAcceptSimilarModelNames() {
        assertEquals(SonyCameraModel.A7CII, SonyCameraModel.fromAdvertisement("ILCE-7CM2.012345"))
        assertEquals(SonyCameraModel.ZVE10, SonyCameraModel.fromAdvertisement("ZV-E10"))
        assertNull(SonyCameraModel.fromAdvertisement("ZV-E10M2"))
        assertNull(SonyCameraModel.fromAdvertisement("Unknown ILCE-7CM2"))
    }

    @Test fun anUnverifiedSonyAdvertisementRemainsSelectableWithoutPretendingVerification() {
        assertEquals(SonyCameraModel.UNKNOWN, SonyCameraModel.fromAdvertisement("ILCE-7M4"))
        assertEquals(SonyCameraModel.UNKNOWN, SonyCameraModel.fromIdentity("ILCE-7M4", "1.00"))
        assertEquals(SonyCameraModel.A7CII, SonyCameraModel.fromIdentity("ILCE-7CM2", "2.00"))
    }

    @Test fun manualNetworkIdentityIsBoundToTheActualCameraAccessPoint() {
        assertEquals("sony-wifi:aa:bb:cc:dd:ee:ff", SonyCameraModel.ZVE10.networkIdentity("\"DIRECT-ab12:ZV-E10\"", "AA:BB:CC:DD:EE:FF"))
        assertNull(SonyCameraModel.ZVE10.networkIdentity("Home", "aa:bb:cc:dd:ee:ff"))
        assertNull(SonyCameraModel.ZVE10.networkIdentity("DIRECT-ab12:ZV-E10M2", "aa:bb:cc:dd:ee:ff"))
        assertNull(SonyCameraModel.ZVE10.networkIdentity("DIRECT-ab12:ZV-E10", "02:00:00:00:00:00"))
        assertNull(SonyCameraModel.ZVE10.networkIdentity("DIRECT-ab12:ZV-E10", null))
    }
}
