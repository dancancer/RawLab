package com.rawlab.android.json

import com.rawlab.android.adjustments.AdjustmentFailure
import com.rawlab.android.adjustments.AdjustmentPayload
import com.rawlab.android.adjustments.AdjustmentTransferException
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.ProcessingIdentity
import com.rawlab.android.settings.ProcessingMigrationQuality
import com.rawlab.android.settings.ProcessingMigrationReceipt
import com.rawlab.android.settings.ProcessingMigrationStatus
import com.rawlab.android.settings.SettingsCodec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class StrictJSONTest {
    @Test fun acceptsStandardRfc8259ValuesAndExactIntegerMetadata() {
        val validInputs = listOf(
            """{"version":2,"exposure":1.0,"scientific":1e0,"negativeZero":-0,"maxLong":${Long.MAX_VALUE},"minLong":${Long.MIN_VALUE}}""",
            """{"outer":{"shared":1},"sibling":{"shared":2},"nested":{"outer":3}}""",
            """{"text":"escaped \" \\ \/ \b \f \n \r \t \u0041 \uD83D\uDE00 \uFEFF"}""",
            """[true, false, null, 0, -42, 3.14159, -2.5E-4, 1E+6]""",
            "[".repeat(63) + "0" + "]".repeat(63),
        )
        for (input in validInputs) {
            validateStrictJSON(input, setOf("version", "negativeZero", "maxLong", "minLong"))
        }
    }

    @Test fun rejectsCommentsTrailingCommasAndLooseOrgJsonSyntax() {
        val looseInputs = listOf(
            "",
            "   \t\r\n  ",
            "\uFEFF{\"a\":1}",
            """{/* block comment */"a":1}""",
            """{"a":1 /* inline comment */}""",
            "{\"a\":1 // line comment\n}",
            "{\"a\":1}# hash comment",
            """{"a":1,}""",
            """[1, 2,]""",
            """[1, , 2]""",
            """{a:1}""",
            """{'a':1}""",
            """{"a":'text'}""",
            """{"a":1;"b":2}""",
            """{"a"=>1}""",
            """{"a":1} true""",
            """{"a":1} trailing""",
        )
        for (invalid in looseInputs) {
            assertThrows(invalid, IllegalArgumentException::class.java) { validateStrictJSON(invalid) }
        }
    }

    @Test fun rejectsDuplicateAndEscapedDuplicateObjectKeysAtEveryDepth() {
        val duplicates = listOf(
            """{"a":1,"a":2}""",
            """{"a":1,"\u0061":2}""",
            """{"nested":{"dup":true,"dup":false}}""",
            """[{"item":1},{"k":1,"\u006B":2}]""",
        )
        for (invalid in duplicates) {
            assertThrows(invalid, IllegalArgumentException::class.java) { validateStrictJSON(invalid) }
        }
    }

    @Test fun rejectsNonStandardNumbersUnescapedControlsInvalidEscapesAndExcessDepth() {
        val malformed = listOf(
            """{"n":01}""",
            """{"n":-01}""",
            """{"n":+1}""",
            """{"n":.5}""",
            """{"n":1.}""",
            """{"n":1e}""",
            """{"n":1e+}""",
            """{"n":NaN}""",
            """{"n":Infinity}""",
            """{"n":-Infinity}""",
            """{"n":0x10}""",
            "{\"s\":\"raw\nnewline\"}",
            "{\"s\":\"raw\ttab\"}",
            "{\"s\":\"nul\u0000byte\"}",
            """{"s":"bad\x20escape"}""",
            """{"s":"bad\aescape"}""",
            """{"s":"bad\u123Ghex"}""",
            """{"s":"short\u12"}""",
            "[".repeat(64) + "0" + "]".repeat(64),
        )
        for (invalid in malformed) {
            assertThrows(invalid, IllegalArgumentException::class.java) { validateStrictJSON(invalid) }
        }
    }

    @Test fun rejectsFloatExponentOverflowAndNonNumericValuesForIntegerKeys() {
        val integerKeyViolations = listOf(
            """{"version":2.0}""",
            """{"version":-0.0}""",
            """{"version":2e0}""",
            """{"version":1E2}""",
            """{"\u0076ersion":2.0}""",
            """{"version":9223372036854775808}""",
            """{"version":-9223372036854775809}""",
            """{"version":"2"}""",
            """{"version":true}""",
            """{"version":null}""",
            """{"version":[]}""",
            """{"version":{}}""",
        )
        for (invalid in integerKeyViolations) {
            assertThrows(invalid, IllegalArgumentException::class.java) {
                validateStrictJSON(invalid, setOf("version"))
            }
        }
    }

    @Test fun persistenceCodecsRejectDuplicateKeysCommentsTrailingCommasAndFloatMetadata() {
        val encodedSettings = SettingsCodec.encode(EditSettings(exposure = 0.5f))
        for (mutated in listOf(
            encodedSettings.replaceFirst("v2:{", "v2:{/*comment*/"),
            encodedSettings.replaceFirst("\"version\":2", "\"version\":1,\"version\":2"),
            encodedSettings.replaceFirst("\"version\":2", "\"version\":2.0"),
            encodedSettings.removeSuffix("}") + ",}",
        )) {
            assertThrows(mutated, IllegalArgumentException::class.java) { SettingsCodec.decode(mutated) }
        }

        val payloadJson = """{"payload_version":1,"scope_version":1,"source":{"identifier":"a","is_raw":true,"processing_version":2},"values":{"light.exposure":1.25}}"""
        for (mutated in listOf(
            payloadJson.replaceFirst("{", "{/*comment*/"),
            payloadJson.replaceFirst("\"light.exposure\":1.25", "\"light.exposure\":0.25,\"light.exposure\":1.25"),
            payloadJson.replaceFirst("\"payload_version\":1", "\"payload_version\":1.0"),
            payloadJson.removeSuffix("}") + ",}",
        )) {
            val error = assertThrows(mutated, AdjustmentTransferException::class.java) { AdjustmentPayload.decode(mutated) }
            assertEquals(AdjustmentFailure.INVALID_PAYLOAD, error.reason)
        }

        val receipt = ProcessingMigrationReceipt(
            ProcessingMigrationStatus.MIGRATED,
            EditSettings(processing = ProcessingIdentity.C5, exposure = 0.25f),
            ProcessingMigrationQuality(0.001f, 0.002f, 0.001f, 0.001f, 20),
        )
        val encodedReceipt = receipt.encode()
        assertEquals(receipt, ProcessingMigrationReceipt.decode(encodedReceipt))
        for (mutated in listOf(
            "/*comment*/$encodedReceipt",
            encodedReceipt.replaceFirst("\"policyVersion\":1", "\"policyVersion\":9,\"policyVersion\":1"),
            encodedReceipt.replaceFirst("\"evaluations\":20", "\"evaluations\":20.0"),
        )) {
            assertThrows(mutated, IllegalArgumentException::class.java) { ProcessingMigrationReceipt.decode(mutated) }
        }
    }
}
