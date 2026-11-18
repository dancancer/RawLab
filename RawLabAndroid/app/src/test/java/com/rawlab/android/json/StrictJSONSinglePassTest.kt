package com.rawlab.android.json

import com.fasterxml.jackson.core.JsonFactory
import com.fasterxml.jackson.core.JsonParser
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class StrictJSONSinglePassTest {
    @Test fun materializesExistingObjectsWithOneParserAndPreservesScalarTypes() {
        val factory = object : JsonFactory() {
            var parserCount = 0
            init { enable(JsonParser.Feature.STRICT_DUPLICATE_DETECTION) }
            override fun createParser(content: String): JsonParser {
                parserCount++
                return super.createParser(content)
            }
        }
        val value = parseStrictJSONObject(
            """{"version":2,"large":9223372036854775807,"values":[null,true,false,-0.0,1.25e-2],"text":"\u7279\u6B8A\n\uD83D\uDE00"}""",
            setOf("version", "large"), factory,
        )
        assertEquals(1, factory.parserCount)
        assertEquals(2, value.get("version"))
        assertEquals(Long.MAX_VALUE, value.get("large"))
        val values = value.getJSONArray("values")
        assertSame(JSONObject.NULL, values.get(0))
        assertEquals(true, values.get(1))
        assertEquals(false, values.get(2))
        assertEquals(0.0125, values.getDouble(4), 0.0)
        assertEquals("特殊\n😀", value.getString("text"))
    }

    @Test fun materializingReadRetainsStrictSyntaxAndIntegerMetadataChecks() {
        for (invalid in listOf(
            """{"a":1,"\u0061":2}""",
            """{"child":{"a":1,"a":2}}""",
            """{/*comment*/"a":1}""",
            """{"a":1,}""",
            """{"a":[1,]}""",
            """{"a":NaN}""",
            """{"a":Infinity}""",
            """{"a":01}""",
            """{"version":2.0}""",
            """{"version":2e0}""",
            """{"version":9223372036854775808}""",
            """{"version":null}""",
            """{"a":1} true""",
            """{"a":"bad\x20escape"}""",
            "{\"a\":" + "[".repeat(63) + "0" + "]".repeat(63) + "}",
        )) {
            assertThrows(invalid, IllegalArgumentException::class.java) {
                parseStrictJSONObject(invalid, setOf("version"))
            }
        }
        val deepest = "{\"a\":" + "[".repeat(62) + "0" + "]".repeat(62) + "}"
        parseStrictJSONObject(deepest)
    }

    @Test fun validationOnlyKeepsStandardOverflowingNumbersLexicallyValid() {
        // Existing Payload/Receipt callers validate syntax before their own numeric/type checks.
        validateStrictJSON("""{"n":1e309}""")
        validateStrictJSON("""{"n":9223372036854775808}""")
        assertThrows(IllegalArgumentException::class.java) {
            validateStrictJSON("""{"version":1e309}""", setOf("version"))
        }
    }
}
