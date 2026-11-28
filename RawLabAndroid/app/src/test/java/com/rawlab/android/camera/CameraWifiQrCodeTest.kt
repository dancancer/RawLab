package com.rawlab.android.camera

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraWifiQrCodeTest {

    @Test
    fun parsesSonyW01ShortSuffixWithModel() {
        val parsed = CameraWifiQrCode.parse("W01:S:6hE1;P:ft67rvUx;C:ZV-E10;M:3690EAE65539;")
        assertNotNull(parsed)
        assertEquals("DIRECT-6hE1:ZV-E10", parsed!!.ssid)
        assertEquals("ft67rvUx", parsed.password)
        assertEquals("ZV-E10", parsed.model)
        assertEquals(CameraWifiQrCredentials.Format.SONY_W01, parsed.format)
    }

    @Test
    fun parsesSonyW01FullDirectSsidWithColon() {
        val parsed = CameraWifiQrCode.parse("W01:S:DIRECT-mRE1:ILCE-6400;P:pass1234;C:ILCE-6400;M:707414B1EFA7;")
        assertNotNull(parsed)
        assertEquals("DIRECT-mRE1:ILCE-6400", parsed!!.ssid)
        assertEquals("pass1234", parsed.password)
        assertEquals("ILCE-6400", parsed.model)
        assertEquals(CameraWifiQrCredentials.Format.SONY_W01, parsed.format)
    }

    @Test
    fun parsesSonyW01FullDirectSsidWithoutModelField() {
        val parsed = CameraWifiQrCode.parse("  w01:S:DIRECT-HnU1:ILCE-7CM2;P:AbCd1234;M:B2653A5145E7;\n")
        assertNotNull(parsed)
        assertEquals("DIRECT-HnU1:ILCE-7CM2", parsed!!.ssid)
        assertEquals("AbCd1234", parsed.password)
        assertEquals("ILCE-7CM2", parsed.model)
    }

    @Test
    fun parsesStandardWifiQrWithEscapes() {
        val parsed = CameraWifiQrCode.parse("""WIFI:T:WPA;S:DIRECT-a1b2\:ZV-E10;P:pa\;ss\\1234;;""")
        assertNotNull(parsed)
        assertEquals("DIRECT-a1b2:ZV-E10", parsed!!.ssid)
        assertEquals("""pa;ss\1234""", parsed.password)
        assertEquals("ZV-E10", parsed.model)
        assertEquals(CameraWifiQrCredentials.Format.STANDARD_WIFI, parsed.format)
    }

    @Test
    fun parsesStandardWifiQrWithWpa2AndSae() {
        val wpa2 = CameraWifiQrCode.parse("WIFI:T:WPA2;S:DIRECT-1234:ZV-E10;P:12345678;;")
        val sae = CameraWifiQrCode.parse("WIFI:T:SAE;S:DIRECT-1234:ILCE-7CM2;P:abcdefgh;;")
        assertNotNull(wpa2)
        assertNotNull(sae)
        assertEquals("DIRECT-1234:ZV-E10", wpa2!!.ssid)
        assertEquals("DIRECT-1234:ILCE-7CM2", sae!!.ssid)
    }

    @Test
    fun rejectsOpenWepShortPasswordAndUnrelatedQr() {
        assertNull(CameraWifiQrCode.parse("https://example.com/camera"))
        assertNull(CameraWifiQrCode.parse(""))
        assertNull(CameraWifiQrCode.parse("W01:S:6hE1;P:short;C:ZV-E10;"))
        assertNull(CameraWifiQrCode.parse("W01:S:;P:12345678;C:ZV-E10;"))
        assertNull(CameraWifiQrCode.parse("W01:S:6hE1;C:ZV-E10;"))
        assertNull(CameraWifiQrCode.parse("WIFI:T:nopass;S:GuestNet;P:12345678;;"))
        assertNull(CameraWifiQrCode.parse("WIFI:T:WEP;S:OldCam;P:12345678;;"))
        assertNull(CameraWifiQrCode.parse("WIFI:T:WPA;S:${"a".repeat(33)};P:12345678;;"))
        assertNull(CameraWifiQrCode.parse("W01:S:6hE1;P:${"x".repeat(64)};C:ZV-E10;"))
        assertNull(CameraWifiQrCode.parse("W01:S:6hE1;P:bad\u0007pass;C:ZV-E10;"))
    }

    @Test
    fun safeSummaryNeverLeaksSsidPasswordOrMac() {
        val raw = "W01:S:6hE1;P:SuperSecretPass99;C:ZV-E10;M:3690EAE65539;"
        val summary = CameraWifiQrCode.safeSummary(raw)
        assertTrue(summary.contains("scheme=W01"))
        assertTrue(summary.contains("valid=true"))
        assertTrue(summary.contains("knownModel=ZVE10"))
        assertFalse(summary.contains("6hE1"))
        assertFalse(summary.contains("SuperSecretPass99"))
        assertFalse(summary.contains("3690EAE65539"))
    }
}
