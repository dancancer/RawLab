package com.rawlab.android.adjustments

import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.HDRCameraDevelopmentSettings
import com.rawlab.android.settings.HDRMode
import com.rawlab.android.settings.HDRRenditionSettings
import com.rawlab.android.settings.HDRLookSettings
import com.rawlab.android.settings.StructuredSettingsCodec
import com.rawlab.android.settings.withHDRMode
import com.rawlab.android.settings.synchronizeHDR
import com.rawlab.android.settings.sdrSnapshotSettings
import com.rawlab.android.settings.HDRToneSettings
import com.rawlab.android.settings.ToneCurveChannel
import com.rawlab.android.settings.ToneCurveShape
import com.rawlab.android.settings.ToneCurveSettings
import com.rawlab.android.settings.withEditingBlackPoint
import com.rawlab.android.settings.withEditingWhitePoint
import com.rawlab.android.settings.withEditingCurve
import com.rawlab.android.settings.withEditingCurveStrength
import com.rawlab.android.settings.withEditingSharpening
import com.rawlab.android.settings.withEditingClarity
import com.rawlab.android.settings.withEditingDehaze
import com.rawlab.android.settings.withHDRDenoise
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HDRAdjustmentTransferTest {
    @Test fun cameraTransferKeepsTargetLensAndRequiresBayerPreflight() {
        val neutral = EditSettings().withHDRMode(true, true)
        val portable = HDRCameraDevelopmentSettings(true, 8400f, 24f, true, 2)
        val source = neutral.copy(hdr = neutral.hdr!!.withCameraDevelopment(portable))
        val lens = HDRCameraDevelopmentSettings(lensTca = true, lensAutoCrop = false, lensProfile = "target lens")
        val target = neutral.copy(hdr = neutral.hdr!!.withCameraDevelopment(lens))
        var preflight: EditSettings? = null
        val context = AdjustmentTransferContext("bayer", true, sourceSupportsCameraHDR = true, validateHDRCamera = { preflight = it })
        val payload = AdjustmentPayload.decode(AdjustmentTransfer.capture(AdjustmentScope.Modified, source, context).encode())
        assertEquals(1, payload.source.hdrProcessingVersion)
        assertEquals(setOf(AdjustmentField.HDR_CAMERA_DEVELOPMENT), payload.fields)
        val prepared = AdjustmentTransfer.prepare(payload, target, context)
        assertEquals(prepared, preflight)
        assertEquals(portable.copy(lensTca = true, lensAutoCrop = false, lensProfile = "target lens"), prepared.hdr!!.cameraSettings)
        org.junit.Assert.assertThrows(AdjustmentTransferException::class.java) {
            AdjustmentTransfer.prepare(payload, target, AdjustmentTransferContext("gain-map", false))
        }
        org.junit.Assert.assertThrows(AdjustmentTransferException::class.java) {
            AdjustmentTransfer.prepare(payload, target, context.copy(validateHDRCamera = null))
        }
    }

    @Test fun hdrLookTransferRequiresMatchingBytesAndKeepsTheDormantEdit() {
        val directory = kotlin.io.path.createTempDirectory("hdr-look-").toFile()
        try {
            val neutral = EditSettings().withHDRMode(true, true)
            val look = HDRLookSettings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "Test HDR", .65f)
            val source = neutral.copy(hdr = neutral.hdr!!.withLook(look))
            val restored = StructuredSettingsCodec.decode(StructuredSettingsCodec.encode(source, "photo_edit"), "photo_edit")
            assertEquals(source, restored)
            val context = AdjustmentTransferContext("hdr", false, hdrLookDirectory = directory)
            val payload = AdjustmentPayload.decode(AdjustmentTransfer.capture(AdjustmentScope.Modified, restored, context).encode())
            assertEquals(7, payload.source.hdrProcessingVersion)
            assertEquals(setOf(AdjustmentField.HDR_LOOK), payload.fields)
            val file = requireNotNull(look.asset(directory))
            file.writeText("abc")
            assertEquals(source, AdjustmentTransfer.prepare(payload, neutral, context))
            file.writeText("def")
            val failure = org.junit.Assert.assertThrows(AdjustmentTransferException::class.java) {
                AdjustmentTransfer.prepare(payload, neutral, context)
            }
            assertEquals(AdjustmentFailure.MISSING_LOOK, failure.reason)
            assertEquals(7, restored.reset().hdr!!.processingVersion)
            assertTrue(restored.reset().hdr!!.lookSettings.isDefault)
        } finally { directory.deleteRecursively() }
    }

    @Test fun detailTransfersFourHdrValuesAndRejectsOrdinaryTargets() {
        val neutral = EditSettings().withHDRMode(true, true)
        val source = neutral.withEditingSharpening(1.25f).withEditingClarity(50f).withEditingDehaze(-25f).withHDRDenoise(.75f)
        val context = AdjustmentTransferContext("hdr", false)
        val payload = AdjustmentTransfer.capture(AdjustmentScope.Modified, source, context)
        val decoded = AdjustmentPayload.decode(payload.encode())
        assertEquals(6, decoded.source.hdrProcessingVersion)
        assertEquals(AdjustmentField.HDR_DETAIL, decoded.fields)
        assertEquals(50.0, decoded[AdjustmentField.CLARITY]?.number)
        assertEquals(-25.0, decoded[AdjustmentField.DEHAZE]?.number)
        assertEquals(source.hdr, AdjustmentTransfer.prepare(decoded, neutral, context).hdr)
        org.junit.Assert.assertThrows(AdjustmentTransferException::class.java) {
            AdjustmentTransfer.prepare(decoded, EditSettings(), context)
        }
    }

    @Test fun independentChannelPayloadKeepsVersionAndAllShapes() {
        val original = EditSettings().withHDRMode(true, true)
        val curve = ToneCurveSettings().replacing(ToneCurveChannel.RED, ToneCurveShape.identity.inserting(.5, .625))
        val source = original.withEditingCurve(curve)
        val context = AdjustmentTransferContext("channels", false)
        val payload = AdjustmentTransfer.capture(AdjustmentScope.Modified, source, context)
        assertEquals(8, payload.source.hdrProcessingVersion)
        val result = AdjustmentTransfer.prepare(AdjustmentPayload.decode(payload.encode()), original, context)
        assertEquals(curve, result.hdr!!.toneSettings.curve)
        assertFalse(result.hdr!!.isIdentity)
        val dormantScalar = HDRToneSettings(curveStrength = .5f, curve = ToneCurveSettings().replacing(ToneCurveChannel.RED, ToneCurveShape.identity))
        assertFalse(dormantScalar.isIdentity)
    }

    @Test fun tonePayloadRoundTripsAndRejectsTheOtherProcessingFamily() {
        val original = EditSettings().withHDRMode(true, true)
        val curve = ToneCurveSettings.identity.inserting(.5, .625)
        val source = original.withEditingBlackPoint(-25f).withEditingWhitePoint(50f)
            .withEditingCurveStrength(.3f).withEditingCurve(curve)
        val context = AdjustmentTransferContext("hdr", false)
        val payload = AdjustmentTransfer.capture(AdjustmentScope.Modified, source, context)
        assertEquals(2, payload.source.hdrProcessingVersion)
        assertEquals(AdjustmentField.HDR_TONE, payload.fields)
        val decoded = AdjustmentPayload.decode(payload.encode())
        assertEquals(source.hdr!!.toneSettings, AdjustmentTransfer.prepare(decoded, original, context).hdr!!.toneSettings)
        org.junit.Assert.assertThrows(AdjustmentTransferException::class.java) {
            AdjustmentTransfer.prepare(decoded, EditSettings(), context)
        }
        org.junit.Assert.assertThrows(AdjustmentTransferException::class.java) {
            AdjustmentPayload(payload.source.copy(hdrProcessingVersion = 1), payload.values)
        }
    }

    @Test fun cameraHdrUsesRelativeValuesAndKeepsTargetDecoderIdentity() {
        val source = EditSettings().withHDRMode(true, false, cameraRaw = true, proRAW = true)
            .copy(exposure = 1f, temperature = 7100f).synchronizeHDR()
        val target = EditSettings(exposure = -2f).withHDRMode(true, false, cameraRaw = true, proRAW = true)
        val proRAW = AdjustmentTransferContext("target", true, sourceSupportsCameraHDR = true, sourceIsProRAW = true)
        val payload = AdjustmentTransfer.capture(AdjustmentScope.All, source, proRAW.copy(identifier = "source"))
        val result = AdjustmentTransfer.prepare(payload, target, proRAW)
        assertEquals(7100f, result.temperature)
        assertEquals(-2f, result.sdrSnapshotSettings()!!.exposure)
        assertEquals(2, result.proRAWDecodeVersion)
        org.junit.Assert.assertThrows(AdjustmentTransferException::class.java) {
            AdjustmentTransfer.prepare(payload, target, AdjustmentTransferContext("ordinary-camera", true))
        }
        org.junit.Assert.assertThrows(AdjustmentTransferException::class.java) {
            AdjustmentTransfer.prepare(payload, target.copy(proRAWDecodeVersion = 99), proRAW)
        }
        org.junit.Assert.assertThrows(AdjustmentTransferException::class.java) {
            AdjustmentTransfer.prepare(payload, EditSettings(), AdjustmentTransferContext("sdr", true))
        }
    }
    @Test fun renditionTransfersBetweenCapableCameraRawAndPreservesTheSdrEdit() {
        val camera = AdjustmentTransferContext("camera", true, sourceSupportsCameraHDR = true)
        val target = EditSettings(exposure = -2f).withHDRMode(true, false, cameraRaw = true)
        val rendition = HDRRenditionSettings(2f, -.75f, 25f, -15f)
        val source = target.copy(hdr = target.hdr!!.withRendition(rendition))
        val payload = AdjustmentTransfer.capture(AdjustmentScope.Modified, source, camera)
        assertEquals(4, payload.source.hdrProcessingVersion)
        assertEquals(AdjustmentField.HDR_RENDITION, payload.fields)
        val prepared = AdjustmentTransfer.prepare(AdjustmentPayload.decode(payload.encode()), target, camera)
        assertEquals(rendition, prepared.hdr!!.renditionSettings)
        assertEquals(target.sdrSnapshot, prepared.sdrSnapshot)
        assertEquals(null, prepared.proRAWDecodeVersion)
        org.junit.Assert.assertThrows(AdjustmentTransferException::class.java) {
            AdjustmentTransfer.prepare(payload, target.copy(proRAWDecodeVersion = 2), camera)
        }
        org.junit.Assert.assertThrows(AdjustmentTransferException::class.java) {
            AdjustmentTransfer.prepare(payload, EditSettings(), camera)
        }
    }
    @Test fun sdrLogicalScalarsReachHdrAndUnsupportedFieldsAreRejectedAsAWhole() {
        val context=AdjustmentTransferContext("hdr",false)
        val target=EditSettings().withHDRMode(true,true)
        val payload=AdjustmentPayload(AdjustmentSource("sdr",false,2),mapOf(AdjustmentField.EXPOSURE to AdjustmentValue.Number(.5)))
        val edited=AdjustmentTransfer.prepare(payload,target,context)
        assertEquals(.5f,edited.hdr!!.exposure)
        assertEquals(0f,edited.sdrSnapshotSettings()!!.exposure)
        org.junit.Assert.assertThrows(AdjustmentTransferException::class.java) {
            AdjustmentTransfer.prepare(AdjustmentPayload(payload.source,payload.values+
                (AdjustmentField.STRENGTH to AdjustmentValue.Number(1.0))),target,context)
        }
    }
    @Test fun modifiedHdrScopeDoesNotIncludeGeometryAndHdrDraftsCannotBeApplied() {
        val target=EditSettings().withHDRMode(true,true).copy(exposure=.5f,
            geometry=com.rawlab.android.geometry.GeometrySettings(quarterTurns=1)).synchronizeHDR()
        val payload=AdjustmentTransfer.capture(AdjustmentScope.Modified,target,AdjustmentTransferContext("hdr",false))
        assertTrue(payload.fields.none {it in AdjustmentField.HDR_GEOMETRY})
        org.junit.Assert.assertThrows(AdjustmentTransferException::class.java) {
            AdjustmentTransfer.prepare(payload,target,AdjustmentTransferContext("hdr",false,hasUncommittedDraft=true))
        }
    }
    @Test
    fun hdrCaptureUsesVersionTwoAndRelativeWhiteBalanceFields() {
        val settings = EditSettings().withHDRMode(true, true)
            .copy(temperature = 7200f, tint = -12f)
            .copy(exposure = 1.25f).synchronizeHDR()

        val payload = AdjustmentTransfer.capture(AdjustmentScope.All, settings,
            AdjustmentTransferContext("hdr-source", isRaw = false))

        assertEquals(2, payload.payloadVersion)
        assertEquals(1, payload.source.hdrProcessingVersion)
        assertTrue(payload.fields.contains(AdjustmentField.HDR_TEMPERATURE))
        assertTrue(payload.fields.contains(AdjustmentField.HDR_TINT))
        assertTrue(!payload.fields.contains(AdjustmentField.TEMPERATURE))
    }

    @Test
    fun hdrPayloadAppliesOnlyToHdrTargetWithoutChangingSdrFields() {
        val source = EditSettings(exposure = 1f).withHDRMode(true, true)
            .copy(temperature = 7200f, tint = -12f).synchronizeHDR()
        val target = EditSettings(exposure = -2f, temperature = 6500f).withHDRMode(true, true)
        val payload = AdjustmentTransfer.capture(AdjustmentScope.All, source,
            AdjustmentTransferContext("hdr-source", isRaw = false))

        val prepared = AdjustmentTransfer.prepare(payload, target,
            AdjustmentTransferContext("hdr-target", isRaw = false))

        assertEquals(HDRMode.HDR, prepared.hdr?.mode)
        assertEquals(1f, prepared.exposure)
        assertEquals(7200f, prepared.temperature)
        assertEquals(-12f, prepared.tint)
        assertEquals(-2f, prepared.sdrSnapshotSettings()?.exposure)
    }
}
